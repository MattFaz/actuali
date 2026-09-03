import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetDatabaseCommonPayeesTests {
    @Test func commonPayeesFollowMergesAndExcludeIneligibleTransactions() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE payees (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    transfer_acct TEXT,
                    tombstone INTEGER DEFAULT 0
                );
                CREATE TABLE payee_mapping (id TEXT PRIMARY KEY, targetId TEXT);
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    description TEXT,
                    date INTEGER,
                    tombstone INTEGER DEFAULT 0,
                    isChild INTEGER DEFAULT 0
                );

                INSERT INTO payees (id, name, transfer_acct, tombstone) VALUES
                    ('frequent', 'Frequent', NULL, 0),
                    ('kept', 'Kept', NULL, 0),
                    ('merged', 'Merged', NULL, 1),
                    ('stale', 'Stale', NULL, 0),
                    ('transfer', 'Transfer', 'account', 0);
                INSERT INTO payee_mapping (id, targetId) VALUES
                    ('frequent', 'frequent'),
                    ('kept', 'kept'),
                    ('merged', 'kept'),
                    ('stale', 'stale'),
                    ('transfer', 'transfer');
                """)
        }

        let now = Date()
        let recent = Transaction.yyyymmdd(from: now)
        let staleDate = try #require(
            Calendar.current.date(byAdding: .weekOfYear, value: -13, to: now)
        )
        let stale = Transaction.yyyymmdd(from: staleDate)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO transactions (id, description, date, tombstone, isChild) VALUES
                    ('frequent-1', 'frequent', ?, 0, 0),
                    ('frequent-2', 'frequent', ?, 0, 0),
                    ('frequent-3', 'frequent', ?, 0, 0),
                    ('kept-merged', 'merged', ?, 0, 0),
                    ('too-old', 'stale', ?, 0, 0),
                    ('child', 'stale', ?, 0, 1),
                    ('deleted', 'stale', ?, 1, 0),
                    ('transfer-1', 'transfer', ?, 0, 0),
                    ('transfer-2', 'transfer', ?, 0, 0),
                    ('transfer-3', 'transfer', ?, 0, 0),
                    ('transfer-4', 'transfer', ?, 0, 0)
                """, arguments: [
                    recent, recent, recent, recent, stale,
                    recent, recent, recent, recent, recent, recent
                ])
        }

        let database = try BudgetDatabase(path: url)
        let store = BudgetStore.previewInstance()
        store.configureForTesting(
            database: database,
            syncClient: SyncClient(
                serverClient: ActualServerClient(),
                nodeId: "89e0e8e90b203f9e"
            )
        )

        #expect(await store.fetchCommonPayees().map(\.name) == ["Frequent", "Kept"])
    }
}
