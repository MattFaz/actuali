import Foundation
import GRDB
import Testing
@testable import Actuali

/// Saving notes back to Actual — categories (GH #131) and accounts (GH #198):
/// the local row is written optimistically and a `notes`/`note` CRDT message is
/// queued for the server.
@MainActor
struct BudgetStoreNoteTests {

    /// The `notes` table plus messages_crdt for the sync write path. Both
    /// normally come from the downloaded budget file.
    private func makeDatabase(
        includeNotesTable: Bool = true,
        seedSQL: String = ""
    ) throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            if includeNotesTable {
                try db.execute(sql: "CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT);")
            }
            try db.execute(sql: """
                CREATE TABLE messages_crdt (
                    id INTEGER PRIMARY KEY,
                    timestamp TEXT NOT NULL UNIQUE,
                    dataset TEXT NOT NULL,
                    row TEXT NOT NULL,
                    column TEXT NOT NULL,
                    value BLOB NOT NULL
                );
                """)
            if !seedSQL.isEmpty {
                try db.execute(sql: seedSQL)
            }
        }
        return (try BudgetDatabase(path: tempURL), tempURL)
    }

    private func makeStore(database: BudgetDatabase) async throws -> BudgetStore {
        let store = BudgetStore.previewInstance()
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        store.configureForTesting(database: database, syncClient: syncClient)
        return store
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func noteRows(_ url: URL) throws -> [Row] {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM notes ORDER BY id")
        }
    }

    private func noteMessages(_ url: URL) throws -> [Row] {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM messages_crdt WHERE dataset = 'notes' ORDER BY id"
            )
        }
    }

    // MARK: - Save normalization (pure)

    @Test func whitespaceOnlyNoteNormalizesToCleared() {
        #expect(EntityNote.normalizedForSave("   \n  ") == "")
        #expect(EntityNote.normalizedForSave("") == "")
    }

    /// Indentation and blank lines inside a real note are deliberate — only
    /// entirely-blank input is treated as a clear.
    @Test func realNoteIsStoredVerbatim() {
        #expect(EntityNote.normalizedForSave("  Cap at $400\n\n    - fuel separate  ")
                == "  Cap at $400\n\n    - fuel separate  ")
    }

    // MARK: - First note for a category

    /// A category with no `notes` row gets one created, and the edit goes out
    /// as a CRDT message so Actual picks it up.
    @Test func savingFirstNoteCreatesRowAndQueuesMessage() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

        try await store.saveNote(id: "cat-groceries", note: "Cap at $400/mo")

        let rows = try noteRows(path)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row["id"] == "cat-groceries")
        #expect(row["note"] == "Cap at $400/mo")

        let messages = try noteMessages(path)
        #expect(messages.count == 1)
        let message = try #require(messages.first)
        #expect(message["row"] == "cat-groceries")
        #expect(message["column"] == "note")
        #expect(message["value"] == "S:Cap at $400/mo")
    }

    /// The saved note is what a subsequent read returns — no manual refresh.
    @Test func savedNoteReadsBack() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

        try await store.saveNote(id: "cat-groceries", note: "Weekly shop only")

        let note = await store.fetchNote(id: "cat-groceries")
        #expect(note.supported)
        #expect(note.text == "Weekly shop only")
    }

    // MARK: - Editing an existing note

    @Test func editingExistingNoteUpdatesRowInPlace() async throws {
        let (database, path) = try makeDatabase(seedSQL: """
            INSERT INTO notes (id, note) VALUES ('cat-groceries', 'old note');
            """)
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

        try await store.saveNote(id: "cat-groceries", note: "new note")

        let rows = try noteRows(path)
        #expect(rows.count == 1)
        #expect(rows.first?["note"] == "new note")
    }

    @Test func savingPreservesMultilineText() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

        try await store.saveNote(id: "cat-groceries", note: "Line one\nLine two")

        let note = await store.fetchNote(id: "cat-groceries")
        #expect(note.text == "Line one\nLine two")
    }

    /// Clearing the text saves an empty string, matching Actual's web UI, so
    /// the cleared state syncs. Tombstoning the row would instead leave other
    /// clients showing the stale note.
    @Test func clearingNoteSavesEmptyStringRatherThanDeletingRow() async throws {
        let (database, path) = try makeDatabase(seedSQL: """
            INSERT INTO notes (id, note) VALUES ('cat-groceries', 'old note');
            """)
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

        try await store.saveNote(id: "cat-groceries", note: "")

        let rows = try noteRows(path)
        #expect(rows.count == 1)
        #expect(rows.first?["note"] == "")

        let messages = try noteMessages(path)
        #expect(messages.count == 1)
        #expect(messages.first?["value"] == "S:")

        let note = await store.fetchNote(id: "cat-groceries")
        #expect(note.isEmpty)
    }

    // MARK: - Account notes

    /// Account notes are keyed `account-<id>`, not the bare account id — that's
    /// the key Actual's own clients read and write (GH #198). Get this wrong and
    /// the note is invisible in both directions: Actual's notes never show in
    /// Actuali, and Actuali's never show in Actual.
    @Test func accountNoteIdCarriesActualsAccountPrefix() {
        #expect(EntityNote.accountNoteId("abc-123") == "account-abc-123")
    }

    /// An account's note goes through the same table and the same write path as
    /// a category's, at the prefixed key — nothing about the save is
    /// category-specific, and this pins the key down end to end.
    @Test func savingAccountNoteWritesRowKeyedByPrefixedAccountId() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

        let noteId = EntityNote.accountNoteId("acct-chase")
        try await store.saveNote(id: noteId, note: "Direct deposit on the 15th")

        let rows = try noteRows(path)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row["id"] == "account-acct-chase")
        #expect(row["note"] == "Direct deposit on the 15th")

        let messages = try noteMessages(path)
        #expect(messages.count == 1)
        #expect(messages.first?["row"] == "account-acct-chase")

        let note = await store.fetchNote(id: noteId)
        #expect(note.supported)
        #expect(note.text == "Direct deposit on the 15th")
    }

    /// An account note written by Actual's web/desktop UI reads back in
    /// Actuali — the case the feature request was actually about.
    @Test func readsAccountNoteWrittenByActual() async throws {
        let (database, path) = try makeDatabase(seedSQL: """
            INSERT INTO notes (id, note) VALUES ('account-acct-chase', 'Buffer $500');
            """)
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

        let note = await store.fetchNote(id: EntityNote.accountNoteId("acct-chase"))
        #expect(note.supported)
        #expect(note.text == "Buffer $500")
    }

    /// A category and an account annotated in the same file keep separate
    /// rows — ids are the only key, so neither edit can clobber the other.
    /// Actual's prefix also means an account and a category can never collide
    /// even if a file somehow reused an id.
    @Test func accountAndCategoryNotesAreIndependent() async throws {
        let (database, path) = try makeDatabase(seedSQL: """
            INSERT INTO notes (id, note) VALUES ('cat-groceries', 'Cap at $400/mo');
            """)
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

        try await store.saveNote(id: EntityNote.accountNoteId("acct-chase"), note: "Buffer $500")

        #expect(await store.fetchNote(id: "cat-groceries").text == "Cap at $400/mo")
        #expect(await store.fetchNote(id: EntityNote.accountNoteId("acct-chase")).text == "Buffer $500")
    }

    // MARK: - Unsupported files and misconfiguration

    /// A file with no `notes` table must fail loudly rather than queue a
    /// message that applies to nothing locally.
    @Test func savingWithoutNotesTableThrows() async throws {
        let (database, path) = try makeDatabase(includeNotesTable: false)
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

        await #expect(throws: SyncError.notesTableMissing) {
            try await store.saveNote(id: "cat-groceries", note: "nope")
        }

        #expect(try noteMessages(path).isEmpty)
    }

    @Test func withoutSyncClientThrowsSyncNotConfigured() async throws {
        let store = BudgetStore.previewInstance()

        await #expect(throws: BudgetStoreError.syncNotConfigured) {
            try await store.saveNote(id: "cat-groceries", note: "nope")
        }
    }

    @Test func fetchWithoutDatabaseIsUnsupported() async throws {
        let store = BudgetStore.previewInstance()

        let note = await store.fetchNote(id: "cat-groceries")
        #expect(!note.supported)
    }
}
