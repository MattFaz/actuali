import Foundation
import Testing
import GRDB
@testable import Actuali

@MainActor
struct BudgetDatabaseCategoryHistoryTests {

    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")

        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    description TEXT,
                    category TEXT,
                    date INTEGER,
                    sort_order REAL,
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

    @Test func returnsNilWhenNoTransactionsForPayee() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        #expect(try await db.mostRecentCategoryId(forPayeeId: "payee-1") == nil)
    }

    @Test func returnsCategoryFromMostRecentTransaction() async throws {
        let (db, url) = try makeDatabase()
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
        let (db, url) = try makeDatabase()
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
        let (db, url) = try makeDatabase()
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
        let (db, url) = try makeDatabase()
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
        let (db, url) = try makeDatabase()
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
