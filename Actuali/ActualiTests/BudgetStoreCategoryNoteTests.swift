import Foundation
import GRDB
import Testing
@testable import Actuali

/// Saving category notes back to Actual (GH #131): the local row is written
/// optimistically and a `notes`/`note` CRDT message is queued for the server.
@MainActor
struct BudgetStoreCategoryNoteTests {

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
        #expect(CategoryNote.normalizedForSave("   \n  ") == "")
        #expect(CategoryNote.normalizedForSave("") == "")
    }

    /// Indentation and blank lines inside a real note are deliberate — only
    /// entirely-blank input is treated as a clear.
    @Test func realNoteIsStoredVerbatim() {
        #expect(CategoryNote.normalizedForSave("  Cap at $400\n\n    - fuel separate  ")
                == "  Cap at $400\n\n    - fuel separate  ")
    }

    // MARK: - First note for a category

    /// A category with no `notes` row gets one created, and the edit goes out
    /// as a CRDT message so Actual picks it up.
    @Test func savingFirstNoteCreatesRowAndQueuesMessage() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

        try await store.saveCategoryNote(categoryId: "cat-groceries", note: "Cap at $400/mo")

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

        try await store.saveCategoryNote(categoryId: "cat-groceries", note: "Weekly shop only")

        let note = await store.fetchCategoryNote(categoryId: "cat-groceries")
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

        try await store.saveCategoryNote(categoryId: "cat-groceries", note: "new note")

        let rows = try noteRows(path)
        #expect(rows.count == 1)
        #expect(rows.first?["note"] == "new note")
    }

    @Test func savingPreservesMultilineText() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

        try await store.saveCategoryNote(categoryId: "cat-groceries", note: "Line one\nLine two")

        let note = await store.fetchCategoryNote(categoryId: "cat-groceries")
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

        try await store.saveCategoryNote(categoryId: "cat-groceries", note: "")

        let rows = try noteRows(path)
        #expect(rows.count == 1)
        #expect(rows.first?["note"] == "")

        let messages = try noteMessages(path)
        #expect(messages.count == 1)
        #expect(messages.first?["value"] == "S:")

        let note = await store.fetchCategoryNote(categoryId: "cat-groceries")
        #expect(note.isEmpty)
    }

    // MARK: - Unsupported files and misconfiguration

    /// A file with no `notes` table must fail loudly rather than queue a
    /// message that applies to nothing locally.
    @Test func savingWithoutNotesTableThrows() async throws {
        let (database, path) = try makeDatabase(includeNotesTable: false)
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

        await #expect(throws: SyncError.notesTableMissing) {
            try await store.saveCategoryNote(categoryId: "cat-groceries", note: "nope")
        }

        #expect(try noteMessages(path).isEmpty)
    }

    @Test func withoutSyncClientThrowsSyncNotConfigured() async throws {
        let store = BudgetStore.previewInstance()

        await #expect(throws: BudgetStoreError.syncNotConfigured) {
            try await store.saveCategoryNote(categoryId: "cat-groceries", note: "nope")
        }
    }

    @Test func fetchWithoutDatabaseIsUnsupported() async throws {
        let store = BudgetStore.previewInstance()

        let note = await store.fetchCategoryNote(categoryId: "cat-groceries")
        #expect(!note.supported)
    }
}
