import Foundation
import Testing
import GRDB
@testable import Actuali

@MainActor
struct CreditCardCycleTests {

    // MARK: - Cycle Date Calculations

    @Test func cycleRangeWhenTodayIsAfterStatementDay() {
        let cycle = CreditCardCycle(accountId: "card1", statementDay: 15)
        // Today is Feb 20, 2026 -> statement day 15 was 5 days ago
        let today = DayDate(year: 2026, month: 2, day: 20)
        let (start, end) = cycle.cycleRange(for: today)

        #expect(start == DayDate(year: 2026, month: 2, day: 16))
        #expect(end == DayDate(year: 2026, month: 3, day: 15))
        #expect(cycle.daysRemainingInCycle(for: today) == 23)
    }

    @Test func cycleRangeWhenTodayIsOnOrBeforeStatementDay() {
        let cycle = CreditCardCycle(accountId: "card1", statementDay: 15)
        // Today is Feb 10, 2026 -> statement day 15 is in 5 days
        let today = DayDate(year: 2026, month: 2, day: 10)
        let (start, end) = cycle.cycleRange(for: today)

        #expect(start == DayDate(year: 2026, month: 1, day: 16))
        #expect(end == DayDate(year: 2026, month: 2, day: 15))
        #expect(cycle.daysRemainingInCycle(for: today) == 5)
    }

    @Test func cycleRangeClampsForShorterMonths() {
        let cycle = CreditCardCycle(accountId: "card1", statementDay: 31)
        // Today is Feb 15, 2026 (non-leap year Feb has 28 days)
        let today = DayDate(year: 2026, month: 2, day: 15)
        let (start, end) = cycle.cycleRange(for: today)

        #expect(start == DayDate(year: 2026, month: 2, day: 1))
        #expect(end == DayDate(year: 2026, month: 2, day: 28))
    }

    @Test func upcomingDueDateFifteenDaysAfterPreviousStatement() {
        let cycle = CreditCardCycle(accountId: "card1", statementDay: 15)
        // Today is Feb 20, 2026: Feb 15 statement closed, due in 15 days (Mar 2, 2026)
        let today = DayDate(year: 2026, month: 2, day: 20)
        let due = cycle.upcomingDueDate(for: today)

        #expect(due == DayDate(year: 2026, month: 3, day: 2))
        #expect(cycle.daysUntilDue(for: today) == 10)
    }

    @Test func upcomingDueDateRollsToCurrentCycleWhenPastPreviousDue() {
        let cycle = CreditCardCycle(accountId: "card1", statementDay: 15)
        // Today is Mar 5, 2026: Feb 15 statement due Mar 2 (passed), so next due is Mar 15 + 15 = Mar 30
        let today = DayDate(year: 2026, month: 3, day: 5)
        let due = cycle.upcomingDueDate(for: today)

        #expect(due == DayDate(year: 2026, month: 3, day: 30))
        #expect(cycle.daysUntilDue(for: today) == 25)
    }

    // MARK: - Store Persistence

    private func withStore(_ body: @MainActor (BudgetStore) async -> Void) async {
        let savedDefault = UserDefaults.standard.string(forKey: "currentBudgetId")
        defer {
            UserDefaults.standard.removeObject(forKey: "creditCardStatementDays_test-budget")
            UserDefaults.standard.set(savedDefault, forKey: "currentBudgetId")
        }
        let store = BudgetStore.previewInstance()
        store.currentBudgetId = "test-budget"
        await body(store)
    }

    @Test func statementDaysPersistInUserDefaults() async {
        await withStore { store in
            store.setCreditCardStatementDay(accountId: "acct_chase", statementDay: 18)
            store.setCreditCardStatementDay(accountId: "acct_apple", statementDay: 31)

            #expect(store.creditCardStatementDays["acct_chase"] == 18)
            #expect(store.creditCardStatementDays["acct_apple"] == 31)
            #expect(store.creditCardCycle(for: "acct_chase")?.statementDay == 18)

            // Remove card
            store.setCreditCardStatementDay(accountId: "acct_chase", statementDay: nil)
            #expect(store.creditCardStatementDays["acct_chase"] == nil)
            #expect(store.creditCardCycle(for: "acct_chase") == nil)
        }
    }

    // MARK: - Database Cycle Spend

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

    @Test func fetchAccountSpendSumsDebitsInRange() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, amount, date, tombstone, isParent) VALUES
                    ('t1', 'card1', -5000, 20260216, 0, 0),  -- in range: $50.00 spend
                    ('t2', 'card1', -2500, 20260220, 0, 0),  -- in range: $25.00 spend
                    ('t3', 'card1', 10000, 20260218, 0, 0),  -- in range payment (positive): ignored for spend
                    ('t4', 'card1', -1500, 20260210, 0, 0),  -- before range: ignored
                    ('t5', 'card1', -3000, 20260320, 0, 0),  -- after range: ignored
                    ('t6', 'card1', -4000, 20260222, 1, 0),  -- tombstoned: ignored
                    ('t7', 'card2', -8000, 20260217, 0, 0);  -- other account: ignored
            """)
        }

        let spend = try await db.fetchAccountSpend(
            accountId: "card1",
            fromDate: 20260216,
            toDate: 20260315
        )

        // 5000 + 2500 = 7500 cents ($75.00)
        #expect(spend == 7500)
    }
}
