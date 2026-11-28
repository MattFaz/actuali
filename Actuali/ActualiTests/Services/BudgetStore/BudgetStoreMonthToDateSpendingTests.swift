import Foundation
import GRDB
import Testing
@testable import Actuali

/// BudgetStore.monthToDateSpending, the Spending vs Last Month widget's
/// figures: this month and last, each from the 1st through today's day number.
struct BudgetStoreMonthToDateSpendingTests {
    /// Noon on the given day, so the day number holds in any time zone.
    private func dayOfMonth(_ day: Int, year: Int = 2026, month: Int = 11) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func lastMonthDatabase(_ rows: String) async throws -> (BudgetDatabase, URL) {
        let (db, url) = try await makeTestDatabase(
            TestSchema.accounts, TestSchema.payees, TestSchema.payeeMapping,
            TestSchema.categories, TestSchema.categoryMapping, TestSchema.transactions
        )
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, offbudget) VALUES ('on', 'Checking', 0), ('off', 'Brokerage', 1);
                INSERT INTO categories (id, name) VALUES ('food', 'Food'), ('fun', 'Fun'), ('secret', 'Secret');
                INSERT INTO category_mapping (id, transferId) VALUES ('food', NULL), ('fun', NULL), ('secret', NULL);
            """ + rows)
        }
        return (db, url)
    }

    @Test func lastMonthToDateSumsLastMonthThroughTheSameDay() async throws {
        let (db, url) = try await lastMonthDatabase("""
            INSERT INTO transactions (id, acct, category, amount, date) VALUES
                ('first-day', 'on',  'food',   -1000, 20261001),
                ('refund',    'on',  'fun',      200, 20261012),
                ('same-day',  'on',  'fun',     -500, 20261025),
                ('day-after', 'on',  'food',   -9000, 20261026),
                ('hidden',    'on',  'secret', -7000, 20261005),
                ('off-budget','off', 'food',   -7000, 20261005),
                ('this-month','on',  'food',   -7000, 20261103),
                ('prior',     'on',  'food',   -7000, 20260930);
        """)
        defer { cleanup(url) }

        let spent = try await BudgetStore.monthToDateSpending(
            in: db, categoryIds: ["food", "fun"], now: dayOfMonth(25, month: 11)
        )

        // Oct 1–25 only, net of the refund: not October's full total.
        #expect(spent.lastMonth == ["food": -1000, "fun": -300])
        #expect(spent.thisMonth == ["food": -7000])
    }

    @Test func lastMonthToDateClampsToTheEndOfAShorterMonth() async throws {
        let (db, url) = try await lastMonthDatabase("""
            INSERT INTO transactions (id, acct, category, amount, date) VALUES
                ('feb-28', 'on', 'food', -400, 20260228),
                ('mar-1',  'on', 'food', -900, 20260301);
        """)
        defer { cleanup(url) }

        let spent = try await BudgetStore.monthToDateSpending(
            in: db, categoryIds: ["food"], now: dayOfMonth(31, month: 3)
        )

        #expect(spent.lastMonth == ["food": -400])
        #expect(spent.thisMonth == ["food": -900])
    }

    @Test func lastMonthToDateIsEmptyWithoutLastMonthData() async throws {
        let (db, url) = try await lastMonthDatabase("""
            INSERT INTO transactions (id, acct, category, amount, date) VALUES
                ('this-month', 'on', 'food', -400, 20261103),
                ('day-after',  'on', 'food', -400, 20261026);
        """)
        defer { cleanup(url) }

        let spent = try await BudgetStore.monthToDateSpending(
            in: db, categoryIds: ["food"], now: dayOfMonth(25, month: 11)
        )

        #expect(spent.lastMonth.isEmpty)
    }

    /// On Nov 5 a rent payment dated Nov 30 is already in the budget file;
    /// it must stay out of "this month so far", as Oct 6 onwards stays out
    /// of last month's side.
    @Test func monthToDateLeavesOutTransactionsDatedLaterThisMonth() async throws {
        let (db, url) = try await lastMonthDatabase("""
            INSERT INTO transactions (id, acct, category, amount, date) VALUES
                ('groceries',  'on', 'food', -3000, 20261102),
                ('today',      'on', 'fun',   -500, 20261105),
                ('rent',       'on', 'food', -150000, 20261130),
                ('oct-early',  'on', 'food', -2000, 20261003),
                ('oct-late',   'on', 'food', -9000, 20261020);
        """)
        defer { cleanup(url) }

        let spent = try await BudgetStore.monthToDateSpending(
            in: db, categoryIds: ["food", "fun"], now: dayOfMonth(5, month: 11)
        )

        #expect(spent.thisMonth == ["food": -3000, "fun": -500])
        #expect(spent.lastMonth == ["food": -2000])
    }
}
