import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetDatabaseTransactionRunningBalanceTests {
    private func seedAccounts(_ db: BudgetDatabase) async throws {
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name) VALUES
                    ('acct-1', 'Checking'),
                    ('acct-2', 'Savings');
            """)
        }
    }

    @Test func filteredRowsMatchBalancesFromTheAllRegister() async throws {
        let (db, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        try await seedAccounts(db)
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, amount, date, sort_order, cleared, reconciled) VALUES
                    ('t-new-uncleared', 'acct-1', -500, 20260604, 4, 0, 0),
                    ('t-cleared-new',   'acct-1',  250, 20260603, 3, 1, 0),
                    ('t-hidden',        'acct-1',  -10, 20260602, 2, 1, 1),
                    ('t-cleared-old',   'acct-1',  500, 20260601, 1, 1, 0);
            """)
        }

        let all = try await db.fetchTransactions(accountId: "acct-1", runningBalanceStartingAt: 1000)
        let cleared = try await db.fetchTransactions(
            accountId: "acct-1", statusFilter: .cleared, runningBalanceStartingAt: 1000
        )

        #expect(all.compactMap(\.runningBalance) == [1000, 1500, 1250, 1260])
        #expect(cleared.map(\.id) == ["t-cleared-new", "t-cleared-old"])
        #expect(cleared.map(\.runningBalance) == all.filter { $0.cleared && !$0.reconciled }.map(\.runningBalance))
    }

    @Test func noAnchorLeavesBalancesUnset() async throws {
        let (db, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        try await seedAccounts(db)
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, amount, date, sort_order, cleared) VALUES
                    ('t-1', 'acct-1', -500, 20260604, 1, 1);
            """)
        }

        let rows = try await db.fetchTransactions(accountId: "acct-1", statusFilter: .cleared)

        #expect(rows.map(\.id) == ["t-1"])
        #expect(rows.first?.runningBalance == nil)
    }

    @Test func sameDateRowsUseSortOrderForBalances() async throws {
        let (db, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        try await seedAccounts(db)
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, amount, date, sort_order, cleared, reconciled) VALUES
                    ('t-new',   'acct-1', -100, 20260604, 3, 0, 0),
                    ('t-middle','acct-1',   50, 20260604, 2, 1, 0),
                    ('t-old',   'acct-1',  200, 20260604, 1, 1, 0);
            """)
        }

        let cleared = try await db.fetchTransactions(
            accountId: "acct-1", statusFilter: .cleared, runningBalanceStartingAt: 500
        )

        #expect(cleared.map(\.id) == ["t-middle", "t-old"])
        #expect(cleared.compactMap(\.runningBalance) == [600, 550])
    }

    @Test func filteredPageBalancesIncludeEarlierRegisterRows() async throws {
        let (db, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        try await seedAccounts(db)
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, amount, date, sort_order, cleared, reconciled) VALUES
                    ('t-new-uncleared', 'acct-1', -500, 20260604, 4, 0, 0),
                    ('t-cleared-new',   'acct-1',  250, 20260603, 3, 1, 0),
                    ('t-hidden',        'acct-1',  -10, 20260602, 2, 1, 1),
                    ('t-cleared-old',   'acct-1',  500, 20260601, 1, 1, 0);
            """)
        }

        let page = try await db.fetchTransactions(
            accountId: "acct-1", limit: 1, offset: 1,
            statusFilter: .cleared, runningBalanceStartingAt: 1000
        )

        #expect(page.map(\.id) == ["t-cleared-old"])
        #expect(page.first?.runningBalance == 1260)
    }

    @Test func balanceWindowUsesOnlyLiveTopLevelRows() async throws {
        let (db, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        try await seedAccounts(db)
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, amount, date, sort_order, isParent, isChild, parent_id, tombstone, cleared, reconciled) VALUES
                    ('t-tombstone', 'acct-1', -900, 20260604, 4, 0, 0, NULL, 1, 0, 0),
                    ('t-live',      'acct-1',  100, 20260603, 3, 0, 0, NULL, 0, 0, 0),
                    ('t-parent',    'acct-1', -200, 20260602, 2, 1, 0, NULL, 0, 1, 0),
                    ('t-child',     'acct-1',  -50, 20260602, 1, 0, 1, 't-parent', 0, 1, 0);
            """)
        }

        let rows = try await db.fetchTransactions(accountId: "acct-1", runningBalanceStartingAt: 1000)

        #expect(rows.map(\.id) == ["t-live", "t-parent"])
        #expect(rows.compactMap(\.runningBalance) == [1000, 900])
    }

    @Test func balancesStayScopedToAccountAndSignedAmounts() async throws {
        let (db, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        try await seedAccounts(db)
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, amount, date, sort_order) VALUES
                    ('t-new',   'acct-1', -100, 20260603, 3),
                    ('t-other', 'acct-2', -5000, 20260602, 2),
                    ('t-old',   'acct-1',   40, 20260601, 1);
            """)
        }

        let rows = try await db.fetchTransactions(accountId: "acct-1", runningBalanceStartingAt: 100)

        #expect(rows.map(\.id) == ["t-new", "t-old"])
        #expect(rows.compactMap(\.runningBalance) == [100, 200])
    }
}
