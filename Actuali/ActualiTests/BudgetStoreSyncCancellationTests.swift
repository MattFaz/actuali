import Foundation
import GRDB
import Testing
@testable import Actuali

/// Pull-to-refresh runs `BudgetStore.sync()` inside SwiftUI's `.refreshable`
/// task, which the system may cancel on further scroll interaction. A
/// cancelled caller must not abort the sync pipeline mid-flight or surface
/// `Swift.CancellationError` to the user — the Reports tab showed a
/// "Something Went Wrong" alert and went blank when that happened.
@MainActor
struct BudgetStoreSyncCancellationTests {

    /// Every table `refreshDataOnly()` reads after a sync, so the refresh
    /// completes without error against this fixture.
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
            """)
        }
        return (try BudgetDatabase(path: tempURL), tempURL)
    }

    /// Store wired to a real database and sync client. The server client is
    /// unconfigured, so the network leg of the sync fails fast and locally;
    /// the data refresh afterwards runs against the fixture for real.
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

    @Test func syncSurvivesCallerCancellationWithoutPublishingError() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database)

        // Cancel before the task body has a chance to run (both are
        // main-actor bound and there is no suspension point in between), so
        // the whole pipeline executes under a cancelled task — exactly what
        // .refreshable does when the gesture cancels the refresh.
        let task = Task { await store.sync() }
        task.cancel()
        await task.value

        #expect(store.error == nil)
        #expect(store.lastSyncTime != nil)
        // The post-sync data refresh must have completed, not been aborted.
        #expect(store.accounts.map(\.name) == ["Checking"])
    }
}
