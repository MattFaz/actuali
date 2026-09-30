import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetDatabaseCategoryHistoryTests {
    private func makeDatabase() async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase(TestSchema.transactions)
    }

    @Test func returnsNilWhenNoTransactionsForPayee() async throws {
        let (db, url) = try await makeDatabase()
        defer { cleanup(url) }

        #expect(try await db.mostRecentCategoryId(forPayeeId: "payee-1") == nil)
    }

    @Test func returnsCategoryFromMostRecentTransaction() async throws {
        let (db, url) = try await makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, description, category, date, sort_order, tombstone) VALUES
                    ('t1', 'payee-1', 'cat-old',    20240101, 1.0, 0),
                    ('t2', 'payee-1', 'cat-recent', 20240501, 2.0, 0);
            """)
        }
        #expect(try await db.mostRecentCategoryId(forPayeeId: "payee-1") == "cat-recent")
    }

    @Test func tiebreaksBySortOrderWhenSameDate() async throws {
        let (db, url) = try await makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, description, category, date, sort_order, tombstone) VALUES
                    ('t1', 'payee-1', 'cat-lower',  20240501, 1.0, 0),
                    ('t2', 'payee-1', 'cat-higher', 20240501, 2.0, 0);
            """)
        }
        #expect(try await db.mostRecentCategoryId(forPayeeId: "payee-1") == "cat-higher")
    }

    @Test func skipsTombstonedTransactions() async throws {
        let (db, url) = try await makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, description, category, date, sort_order, tombstone) VALUES
                    ('t1', 'payee-1', 'cat-old',     20240101, 1.0, 0),
                    ('t2', 'payee-1', 'cat-deleted', 20240501, 2.0, 1);
            """)
        }
        #expect(try await db.mostRecentCategoryId(forPayeeId: "payee-1") == "cat-old")
    }

    @Test func skipsTransactionsWithNilCategory() async throws {
        let (db, url) = try await makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, description, category, date, sort_order, tombstone) VALUES
                    ('t1', 'payee-1', 'cat-old', 20240101, 1.0, 0),
                    ('t2', 'payee-1', NULL,      20240501, 2.0, 0);
            """)
        }
        #expect(try await db.mostRecentCategoryId(forPayeeId: "payee-1") == "cat-old")
    }

    @Test func filtersByPayeeId() async throws {
        let (db, url) = try await makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, description, category, date, sort_order, tombstone) VALUES
                    ('t1', 'payee-2', 'cat-other', 20240601, 1.0, 0),
                    ('t2', 'payee-1', 'cat-mine',  20240501, 1.0, 0);
            """)
        }
        #expect(try await db.mostRecentCategoryId(forPayeeId: "payee-1") == "cat-mine")
    }
}
