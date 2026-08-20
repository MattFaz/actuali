import Foundation
import Testing
@testable import Actuali

@MainActor
struct CreditCardCycleTests {

    // MARK: - Cycle Date Calculations

    @Test func cycleRangeWhenTodayIsAfterStatementDay() {
        let cycle = CreditCardCycle(statementDay: 15)
        // Today is Feb 20, 2026 -> statement day 15 was 5 days ago
        let today = DayDate(year: 2026, month: 2, day: 20)
        let (start, end) = cycle.cycleRange(for: today)

        #expect(start == DayDate(year: 2026, month: 2, day: 16))
        #expect(end == DayDate(year: 2026, month: 3, day: 15))
        #expect(cycle.daysRemainingInCycle(for: today) == 23)
    }

    @Test func cycleRangeWhenTodayIsOnOrBeforeStatementDay() {
        let cycle = CreditCardCycle(statementDay: 15)
        // Today is Feb 10, 2026 -> statement day 15 is in 5 days
        let today = DayDate(year: 2026, month: 2, day: 10)
        let (start, end) = cycle.cycleRange(for: today)

        #expect(start == DayDate(year: 2026, month: 1, day: 16))
        #expect(end == DayDate(year: 2026, month: 2, day: 15))
        #expect(cycle.daysRemainingInCycle(for: today) == 5)
    }

    @Test func cycleRangeClampsForShorterMonths() {
        let cycle = CreditCardCycle(statementDay: 31)
        // Today is Feb 15, 2026 (non-leap year Feb has 28 days)
        let today = DayDate(year: 2026, month: 2, day: 15)
        let (start, end) = cycle.cycleRange(for: today)

        #expect(start == DayDate(year: 2026, month: 2, day: 1))
        #expect(end == DayDate(year: 2026, month: 2, day: 28))
    }

    @Test func upcomingDueDateFifteenDaysAfterPreviousStatement() {
        let cycle = CreditCardCycle(statementDay: 15)
        // Today is Feb 20, 2026: Feb 15 statement closed, due in 15 days (Mar 2, 2026)
        let today = DayDate(year: 2026, month: 2, day: 20)
        let due = cycle.upcomingDueDate(for: today)

        #expect(due == DayDate(year: 2026, month: 3, day: 2))
        #expect(cycle.daysUntilDue(for: today) == 10)
    }

    @Test func upcomingDueDateRollsToCurrentCycleWhenPastPreviousDue() {
        let cycle = CreditCardCycle(statementDay: 15)
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
}
