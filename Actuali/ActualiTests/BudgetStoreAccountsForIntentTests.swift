import Foundation
import Testing
import GRDB
@testable import Actuali

/// Regression coverage for actios-2v0: the Log Transaction Shortcut reported
/// "Account is no longer available" on a cold/headless launch because the
/// `AccountEntityQuery` read the still-empty in-memory `accounts` cache before
/// the async budget load had run. `accountsForIntent()` must fall back to a
/// direct database read when the cache is empty.
@MainActor
struct BudgetStoreAccountsForIntentTests {

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
                    acct TEXT,
                    category TEXT,
                    description TEXT,
                    amount INTEGER,
                    date INTEGER,
                    transferred_id TEXT,
                    sort_order REAL,
                    tombstone INTEGER DEFAULT 0,
                    isParent INTEGER DEFAULT 0,
                    isChild INTEGER DEFAULT 0,
                    parent_id TEXT
                );
            """)
        }
        let database = try BudgetDatabase(path: tempURL)
        return (database, tempURL)
    }

    private func makeStore(database: BudgetDatabase) async throws -> BudgetStore {
        let store = BudgetStore.previewInstance()
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        store.configureForTesting(database: database, syncClient: syncClient)
        return store
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// The bug: an empty in-memory cache (cold headless launch) must still
    /// resolve accounts by reading the attached database.
    @Test func resolvesAccountsFromDatabaseWhenCacheIsEmpty() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, type, closed, sort_order) VALUES
                    ('acct-checking', 'Checking', 'checking', 0, 1.0),
                    ('acct-closed',   'Old Card', 'credit',   1, 2.0);
            """)
        }

        let store = try await makeStore(database: db)
        #expect(store.accounts.isEmpty)  // preview store never auto-loads

        let resolved = await store.accountsForIntent()
        #expect(Set(resolved.map(\.id)) == ["acct-checking", "acct-closed"])

        // The saved account parameter resolves even though the cache was empty.
        let checking = resolved.first { $0.id == "acct-checking" }
        #expect(checking?.name == "Checking")
        #expect(checking?.closed == false)
    }

    /// When the cache is already populated (warm process) it is used as-is and
    /// the database is not consulted.
    @Test func usesInMemoryCacheWhenPopulated() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        // DB has one account; cache has a different one — cache must win.
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, type, sort_order)
                VALUES ('from-db', 'From DB', 'checking', 1.0);
            """)
        }

        let store = try await makeStore(database: db)
        store.accounts = [
            Account(id: "from-cache", name: "From Cache", type: .checking,
                    offBudget: false, closed: false, sortOrder: 0, balance: 0)
        ]

        let resolved = await store.accountsForIntent()
        #expect(resolved.map(\.id) == ["from-cache"])
    }

    /// No budget/database available: resolve to empty rather than crashing.
    @Test func returnsEmptyWhenNoDatabaseAvailable() async throws {
        let store = BudgetStore.previewInstance()
        #expect(store.accounts.isEmpty)

        let resolved = await store.accountsForIntent()
        #expect(resolved.isEmpty)
    }
}
