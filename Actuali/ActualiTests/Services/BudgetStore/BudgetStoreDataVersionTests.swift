import Foundation
import GRDB
import Testing
@testable import Actuali

/// `dataVersion` is the store's change signal: views that cache their own
/// fetches (transaction pagers, report widgets) key reloads on it, so it must
/// bump whenever the published data snapshot is republished — after a local
/// mutation and after a sync.
@MainActor
struct BudgetStoreDataVersionTests {

    /// Every table `refreshDataOnly()` reads, so the refresh completes
    /// without error (matches BudgetStoreSyncCancellationTests).
    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")

        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    type TEXT,
                    offbudget INTEGER DEFAULT 0,
                    closed INTEGER DEFAULT 0,
                    sort_order REAL,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    isParent INTEGER DEFAULT 0,
                    isChild INTEGER DEFAULT 0,
                    acct TEXT,
                    category TEXT,
                    description TEXT,
                    amount INTEGER,
                    notes TEXT,
                    date INTEGER,
                    imported_description TEXT,
                    financial_id TEXT,
                    transferred_id TEXT,
                    cleared INTEGER DEFAULT 0,
                    reconciled INTEGER DEFAULT 0,
                    sort_order REAL,
                    parent_id TEXT,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE payees (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    transfer_acct TEXT,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE payee_mapping (
                    id TEXT PRIMARY KEY,
                    targetId TEXT
                );

                CREATE TABLE categories (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    is_income INTEGER DEFAULT 0,
                    cat_group TEXT,
                    sort_order REAL,
                    hidden INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE category_groups (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    is_income INTEGER DEFAULT 0,
                    sort_order REAL,
                    hidden INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE category_mapping (
                    id TEXT PRIMARY KEY,
                    transferId TEXT
                );

                CREATE TABLE messages_crdt (
                    id INTEGER PRIMARY KEY,
                    timestamp TEXT NOT NULL UNIQUE,
                    dataset TEXT NOT NULL,
                    row TEXT NOT NULL,
                    column TEXT NOT NULL,
                    value BLOB NOT NULL
                );

                INSERT INTO accounts (id, name, type, sort_order) VALUES
                    ('acct-1', 'Checking', 'checking', 1.0);
                INSERT INTO transactions (id, acct, amount, date, cleared, sort_order) VALUES
                    ('t1', 'acct-1', -500, 20260701, 0, 1.0);
            """)
        }
        return (try BudgetDatabase(path: tempURL), tempURL)
    }

    /// Store wired to a real database and sync client. The server client is
    /// unconfigured, so the network leg fails fast and locally; the data
    /// refresh afterwards runs against the fixture for real.
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

    @Test func localMutationBumpsDataVersion() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database)
        let before = store.dataVersion

        // The cross-tab scenario the signal exists for: a dot-tap toggle on
        // one screen must announce itself to every cached list.
        let transaction = Transaction(
            id: "t1",
            accountId: "acct-1",
            date: 20260701,
            amount: -500,
            payeeId: nil,
            payeeName: nil,
            categoryId: nil,
            categoryName: nil,
            notes: nil,
            cleared: false,
            reconciled: false,
            transferId: nil,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: 1,
            importedPayee: nil
        )
        await store.toggleCleared(transaction)

        #expect(store.error == nil)
        #expect(store.dataVersion > before)
    }

    @Test func syncBumpsDataVersion() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database)
        let before = store.dataVersion

        await store.sync()

        #expect(store.error == nil)
        #expect(store.dataVersion > before)
    }
}
