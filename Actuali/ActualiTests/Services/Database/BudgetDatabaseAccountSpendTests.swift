import Foundation
import Testing
import GRDB
@testable import Actuali

@MainActor
struct BudgetDatabaseAccountSpendTests {

    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")

        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    acct TEXT,
                    category TEXT,
                    description TEXT,
                    amount INTEGER,
                    date INTEGER,
                    transferred_id TEXT,
                    sort_order REAL,
                    isParent INTEGER DEFAULT 0,
                    isChild INTEGER DEFAULT 0,
                    parent_id TEXT,
                    tombstone INTEGER DEFAULT 0
                );
            """)
        }
        let database = try BudgetDatabase(path: tempURL)
        return (database, tempURL)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test func fetchAccountSpendSumsDebitsInRangeWithSplitAndTombstoneFilters() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, amount, date, tombstone, isParent, isChild, parent_id) VALUES
                    ('t1', 'card1', -5000, 20260216, 0, 0, 0, NULL),   -- on fromDate: counted ($50.00)
                    ('t2', 'card1', -2500, 20260220, 0, 0, 0, NULL),   -- in range: $25.00 spend
                    ('t3', 'card1', 10000, 20260218, 0, 0, 0, NULL),   -- in range payment (positive): ignored for spend
                    ('t4', 'card1', -1500, 20260210, 0, 0, 0, NULL),   -- before range: ignored
                    ('t5', 'card1', -3000, 20260320, 0, 0, 0, NULL),   -- after range: ignored
                    ('t6', 'card1', -4000, 20260222, 1, 0, 0, NULL),   -- tombstoned: ignored
                    ('t7', 'card2', -8000, 20260217, 0, 0, 0, NULL),   -- other account: ignored
                    ('t8', 'card1', -1000, 20260315, 0, 0, 0, NULL),   -- on toDate: counted ($10.00)
                    ('t9', 'card1', -7000, 20260316, 0, 0, 0, NULL),   -- day after toDate: ignored
                    ('p1', 'card1', -9000, 20260217, 0, 1, 0, NULL),   -- split parent: excluded
                    ('c1', 'card1', -6000, 20260217, 0, 0, 1, 'p1'),   -- alive child: counted ($60.00)
                    ('c2', 'card1', -3000, 20260217, 0, 0, 1, 'p1'),   -- alive child: counted ($30.00)
                    ('p2', 'card1', -4000, 20260219, 1, 1, 0, NULL),   -- tombstoned parent
                    ('c3', 'card1', -4000, 20260219, 0, 0, 1, 'p2');   -- orphan child of tombstoned parent: excluded
            """)
        }

        // Both bounds are inclusive, and the statement closing day is the single
        // most likely date for a charge to land on, so t1 and t8 pin the ends.
        let spend = try await db.fetchAccountSpend(
            accountId: "card1",
            fromDate: 20260216,
            toDate: 20260315
        )

        // 5000 + 2500 + 1000 + 6000 + 3000 = 17500 cents ($175.00)
        #expect(spend == 17500)
    }
}
