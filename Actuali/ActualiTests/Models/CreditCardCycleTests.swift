import Foundation
import GRDB
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

    @Test func cycleRangeStartsDayAfterAClampedPreviousStatement() {
        let cycle = CreditCardCycle(statementDay: 31)
        // Today is Mar 1, 2026: the Feb statement clamped to Feb 28, so the
        // active cycle starts Mar 1 rather than repeating a Feb 31 that never
        // existed.
        let today = DayDate(year: 2026, month: 3, day: 1)
        let (start, end) = cycle.cycleRange(for: today)

        #expect(start == DayDate(year: 2026, month: 3, day: 1))
        #expect(end == DayDate(year: 2026, month: 3, day: 31))
        #expect(cycle.previousStatementDate(for: today) == DayDate(year: 2026, month: 2, day: 28))
    }

    @Test func cycleRangeClosesTodayWhenTodayIsTheStatementDay() {
        let cycle = CreditCardCycle(statementDay: 15)
        let today = DayDate(year: 2026, month: 2, day: 15)
        let (start, end) = cycle.cycleRange(for: today)

        #expect(start == DayDate(year: 2026, month: 1, day: 16))
        #expect(end == today)
        #expect(cycle.daysRemainingInCycle(for: today) == 0)
    }

    @Test func cycleRangeRollsForwardOverYearEnd() {
        let cycle = CreditCardCycle(statementDay: 15)
        // Today is Dec 20, 2026 -> the cycle closes in January of the next year.
        let today = DayDate(year: 2026, month: 12, day: 20)
        let (start, end) = cycle.cycleRange(for: today)

        #expect(start == DayDate(year: 2026, month: 12, day: 16))
        #expect(end == DayDate(year: 2027, month: 1, day: 15))
    }

    @Test func cycleRangeRollsBackwardOverYearEnd() {
        let cycle = CreditCardCycle(statementDay: 15)
        // Today is Jan 10, 2027 -> the cycle opened in December of the prior year.
        let today = DayDate(year: 2027, month: 1, day: 10)
        let (start, end) = cycle.cycleRange(for: today)

        #expect(start == DayDate(year: 2026, month: 12, day: 16))
        #expect(end == DayDate(year: 2027, month: 1, day: 15))
    }

    // MARK: - Payment Due Dates

    @Test func upcomingDueDateUsesTheConfiguredOffsetAfterPreviousStatement() {
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

    @Test func upcomingDueDateHonoursALongerPerCardOffset() {
        let cycle = CreditCardCycle(statementDay: 15, paymentDue: .daysAfter(25))
        // Today is Feb 20, 2026: Feb 15 statement + 25 days = Mar 12.
        let today = DayDate(year: 2026, month: 2, day: 20)

        #expect(cycle.upcomingDueDate(for: today) == DayDate(year: 2026, month: 3, day: 12))
        #expect(cycle.daysUntilDue(for: today) == 20)
    }

    /// A 45-day offset leaves two statements awaiting payment at once, so the
    /// next payment belongs to the *older* one. Returning the most recent
    /// statement's due date would skip a payment the user still owes.
    @Test func upcomingDueDatePicksTheEarliestStatementStillAwaitingPayment() {
        let cycle = CreditCardCycle(statementDay: 15, paymentDue: .daysAfter(45))
        let today = DayDate(year: 2026, month: 2, day: 20)

        // Jan 15 statement -> due Mar 1; Feb 15 statement -> due Apr 1.
        #expect(cycle.upcomingDueDate(for: today) == DayDate(year: 2026, month: 3, day: 1))
        #expect(cycle.daysUntilDue(for: today) == 9)
    }

    @Test func upcomingDueDateAdvancesOnceTheEarliestPendingDuePasses() {
        let cycle = CreditCardCycle(statementDay: 15, paymentDue: .daysAfter(45))
        // Mar 2 is one day past the Jan 15 statement's Mar 1 due date, so the
        // Feb 15 statement's Apr 1 due date is now the next one.
        let today = DayDate(year: 2026, month: 3, day: 2)

        #expect(cycle.upcomingDueDate(for: today) == DayDate(year: 2026, month: 4, day: 1))
    }

    @Test func upcomingDueDateTerminatesAtTheWidestOffset() {
        let cycle = CreditCardCycle(statementDay: 15, paymentDue: .daysAfter(CreditCardCycle.maxDueOffsetDays))
        let today = DayDate(year: 2026, month: 2, day: 20)
        // Dec 15 statement + 60 days = Feb 13 (passed), so Jan 15 + 60 is next.
        #expect(cycle.upcomingDueDate(for: today) == DayDate(year: 2026, month: 3, day: 16))
    }

    /// Both the Credit Cards row and the account detail header render this, so
    /// the near-term wording is worth pinning.
    @Test func dueSummaryReadsAsPlainEnglishNearTheDueDate() {
        let cycle = CreditCardCycle(statementDay: 15)
        // Feb 15 statement + 15 days = Mar 2, 2026.
        #expect(cycle.dueSummary(for: DayDate(year: 2026, month: 3, day: 2)) == "Due today")
        #expect(cycle.dueSummary(for: DayDate(year: 2026, month: 3, day: 1)) == "Due tomorrow")
        #expect(cycle.dueSummary(for: DayDate(year: 2026, month: 2, day: 20)).hasPrefix("Due "))
        #expect(cycle.dueSummary(for: DayDate(year: 2026, month: 2, day: 20)).hasSuffix("(10d)"))
    }

    @Test func dueShortSummaryMatchesTheLongFormNearTheDueDate() {
        let cycle = CreditCardCycle(statementDay: 15)
        // Feb 15 statement + 15 days = Mar 2, 2026.
        #expect(cycle.dueShortSummary(for: DayDate(year: 2026, month: 3, day: 2)) == "Due today")
        #expect(cycle.dueShortSummary(for: DayDate(year: 2026, month: 3, day: 1)) == "Due tomorrow")
        #expect(cycle.dueShortSummary(for: DayDate(year: 2026, month: 2, day: 20)) == "Due in 10d")
    }

    @Test func dueDayEqualToStatementDayFallsInTheNextMonth() {
        let cycle = CreditCardCycle(statementDay: 15, paymentDue: .dayOfMonth(15))
        // Jan 15 statement closes, payment is due Feb 15.
        #expect(cycle.dueDate(forStatement: DayDate(year: 2026, month: 1, day: 15))
            == DayDate(year: 2026, month: 2, day: 15))
        #expect(cycle.upcomingDueDate(for: DayDate(year: 2026, month: 1, day: 20))
            == DayDate(year: 2026, month: 2, day: 15))
    }

    @Test func dueOffsetDaysForDayOfMonthFallsBackToDefault() {
        let cycle = CreditCardCycle(statementDay: 15, paymentDue: .dayOfMonth(1))
        #expect(cycle.dueOffsetDays == CreditCardCycle.defaultDueOffsetDays)
    }

    @Test func upcomingDueDateWhenDueDayIsNextMonth() {
        let cycle = CreditCardCycle(statementDay: 15, paymentDue: .dayOfMonth(1))
        // Today is Feb 20, 2026: Feb 15 statement closed, due on Mar 1, 2026
        let today = DayDate(year: 2026, month: 2, day: 20)
        let due = cycle.upcomingDueDate(for: today)

        #expect(due == DayDate(year: 2026, month: 3, day: 1))
        #expect(cycle.daysUntilDue(for: today) == 9)
    }

    @Test func upcomingDueDateWhenDueDayIsSameMonth() {
        let cycle = CreditCardCycle(statementDay: 5, paymentDue: .dayOfMonth(25))
        // Today is Jan 10, 2026: Jan 5 statement closed, due on Jan 25, 2026
        let today = DayDate(year: 2026, month: 1, day: 10)
        let due = cycle.upcomingDueDate(for: today)

        #expect(due == DayDate(year: 2026, month: 1, day: 25))
        #expect(cycle.daysUntilDue(for: today) == 15)
    }

    @Test func upcomingDueDateRollsToCurrentCycleWhenPastPreviousDueDay() {
        let cycle = CreditCardCycle(statementDay: 15, paymentDue: .dayOfMonth(1))
        // Today is Mar 2, 2026: Feb 15 statement was due Mar 1 (passed),
        // so next due is Mar 15 statement due Apr 1
        let today = DayDate(year: 2026, month: 3, day: 2)
        let due = cycle.upcomingDueDate(for: today)

        #expect(due == DayDate(year: 2026, month: 4, day: 1))
        #expect(cycle.daysUntilDue(for: today) == 30)
    }

    @Test func upcomingDueDateClampsForShorterMonthsWithDueDay() {
        let cycle = CreditCardCycle(statementDay: 15, paymentDue: .dayOfMonth(31))
        // Feb 15, 2026 statement -> due on Feb 28 (clamped to month end)
        let today = DayDate(year: 2026, month: 2, day: 20)
        #expect(cycle.upcomingDueDate(for: today) == DayDate(year: 2026, month: 2, day: 28))
    }

    @Test func upcomingDueDateRollsOverYearEndWithDueDay() {
        let cycle = CreditCardCycle(statementDay: 15, paymentDue: .dayOfMonth(1))
        // Today is Dec 20, 2026: Dec 15 statement closed, due on Jan 1, 2027
        let today = DayDate(year: 2026, month: 12, day: 20)
        #expect(cycle.upcomingDueDate(for: today) == DayDate(year: 2027, month: 1, day: 1))
    }

    @Test func dueSummaryWithDueDayReadsAccurately() {
        let cycle = CreditCardCycle(statementDay: 15, paymentDue: .dayOfMonth(1))
        #expect(cycle.dueSummary(for: DayDate(year: 2026, month: 3, day: 1)) == "Due today")
        #expect(cycle.dueSummary(for: DayDate(year: 2026, month: 2, day: 28)) == "Due tomorrow")
        #expect(cycle.dueSummary(for: DayDate(year: 2026, month: 2, day: 20)).hasPrefix("Due "))
        #expect(cycle.dueSummary(for: DayDate(year: 2026, month: 2, day: 20)).hasSuffix("(9d)"))
        #expect(cycle.dueShortSummary(for: DayDate(year: 2026, month: 2, day: 20)) == "Due in 9d")
    }

    // MARK: - Store Persistence

    /// Points the store at throwaway budget ids and configures test database and sync client.
    private func withStore(
        budgetIds: [String] = ["test-budget"],
        _ body: @MainActor (BudgetStore) async throws -> Void
    ) async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let queue = try DatabaseQueue(path: tempURL.path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
                CREATE TABLE messages_crdt (id INTEGER PRIMARY KEY, timestamp TEXT NOT NULL UNIQUE, dataset TEXT NOT NULL, row TEXT NOT NULL, column TEXT NOT NULL, value BLOB NOT NULL);
            """)
        }
        let database = try BudgetDatabase(path: tempURL)
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        let store = BudgetStore.previewInstance()
        store.configureForTesting(database: database, syncClient: syncClient)
        store.currentBudgetId = budgetIds[0]
        try await body(store)
    }

    @Test func statementDaysPersistAndClearInStore() async throws {
        try await withStore { store in
            await store.setCreditCard(accountId: "acct_chase", statementDay: 18, limit: nil)
            await store.setCreditCard(accountId: "acct_apple", statementDay: 31, limit: nil)

            #expect(store.creditCardStatementDays["acct_chase"] == 18)
            #expect(store.creditCardStatementDays["acct_apple"] == 31)
            #expect(store.creditCardCycle(for: "acct_chase")?.statementDay == 18)

            // Remove card
            await store.setCreditCard(accountId: "acct_chase", statementDay: nil, limit: nil)
            #expect(store.creditCardStatementDays["acct_chase"] == nil)
            #expect(store.creditCardCycle(for: "acct_chase") == nil)
        }
    }

    @Test func dueOffsetPersistsAndClearsWithTheCard() async throws {
        try await withStore { store in
            await store.setCreditCard(accountId: "acct_anz", statementDay: 20, paymentDue: .daysAfter(45), limit: nil)

            #expect(store.creditCardDueOffsets["acct_anz"] == 45)
            #expect(store.creditCardCycle(for: "acct_anz")?.dueOffsetDays == 45)

            // Removing the card must not leave the offset behind to be picked up
            // by a later card on the same account.
            await store.setCreditCard(accountId: "acct_anz", statementDay: nil, limit: nil)
            #expect(store.creditCardDueOffsets["acct_anz"] == nil)
        }
    }

    @Test func dueDayPersistsAndClearsWithTheCard() async throws {
        try await withStore { store in
            await store.setCreditCard(accountId: "acct_alipay", statementDay: 15, paymentDue: .dayOfMonth(1), limit: nil)

            #expect(store.creditCardCycle(for: "acct_alipay")?.paymentDue == .dayOfMonth(1))

            await store.setCreditCard(accountId: "acct_alipay", statementDay: nil, limit: nil)
            #expect(store.creditCardCycle(for: "acct_alipay") == nil)
        }
    }

    /// Cards configured before the offset was per-card have a statement day and
    /// no offset; they must keep working on the previous fixed 15 days.
    @Test func cardWithNoStoredOffsetFallsBackToTheDefault() async throws {
        try await withStore { store in
            store.creditCardConfigs["acct_legacy"] = CreditCardConfig(statementDay: 10)

            let cycle = store.creditCardCycle(for: "acct_legacy")
            #expect(cycle?.statementDay == 10)
            #expect(cycle?.dueOffsetDays == CreditCardCycle.defaultDueOffsetDays)
        }
    }

    @Test func cardConfigIsScopedToTheBudgetThatSetIt() async throws {
        try await withStore(budgetIds: ["budget-a", "budget-b"]) { store in
            await store.setCreditCard(accountId: "acct_chase", statementDay: 18, paymentDue: .daysAfter(25), limit: nil)

            store.currentBudgetId = "budget-b"
            #expect(store.creditCardStatementDays.isEmpty)
            #expect(store.creditCardDueOffsets.isEmpty)
            #expect(store.creditCardCycle(for: "acct_chase") == nil)
        }
    }

    @Test func cardConfigIsUnreachableWithNoOpenBudget() async throws {
        try await withStore { store in
            await store.setCreditCard(accountId: "acct_chase", statementDay: 18, limit: nil)

            store.currentBudgetId = nil
            #expect(store.creditCardStatementDays.isEmpty)
            #expect(store.creditCardCycle(for: "acct_chase") == nil)

            // The setter has nowhere to write, so it must not trap or leak into
            // another budget's keys.
            await store.setCreditCard(accountId: "acct_other", statementDay: 3, limit: nil)
            #expect(store.creditCardStatementDays.isEmpty)
        }
    }

    /// The Settings badge and the Credit Cards list both read this, so a closed
    /// or deleted account must drop out of it — otherwise the badge counts cards
    /// the list refuses to show.
    @Test func activeStatementDaysExcludeClosedAndMissingAccounts() async throws {
        try await withStore { store in
            store.accounts = [
                account(id: "acct_open", name: "Open Card"),
                account(id: "acct_closed", name: "Closed Card", closed: true),
            ]
            await store.setCreditCard(accountId: "acct_open", statementDay: 15, limit: nil)
            await store.setCreditCard(accountId: "acct_closed", statementDay: 20, limit: nil)
            await store.setCreditCard(accountId: "acct_deleted", statementDay: 25, limit: nil)

            #expect(store.creditCardStatementDays.count == 3)
            #expect(store.activeCreditCardStatementDays == ["acct_open": 15])

            // Reopening the account restores its cycle rather than losing it.
            store.accounts = [
                account(id: "acct_open", name: "Open Card"),
                account(id: "acct_closed", name: "Closed Card"),
            ]
            #expect(store.activeCreditCardStatementDays.count == 2)
        }
    }

    /// The account detail screen reads this rather than `creditCardCycle(for:)`,
    /// so a closed card can't keep advertising a payment due date there after it
    /// has dropped off the Credit Cards screen.
    @Test func activeCycleIsNilForClosedAndMissingAccounts() async throws {
        try await withStore { store in
            store.accounts = [
                account(id: "acct_open", name: "Open Card"),
                account(id: "acct_closed", name: "Closed Card", closed: true),
                account(id: "acct_untracked", name: "Everyday Checking", type: .checking),
            ]
            await store.setCreditCard(accountId: "acct_open", statementDay: 15, paymentDue: .daysAfter(25), limit: nil)
            await store.setCreditCard(accountId: "acct_closed", statementDay: 20, limit: nil)
            await store.setCreditCard(accountId: "acct_deleted", statementDay: 25, limit: nil)

            #expect(store.activeCreditCardCycle(for: "acct_open")?.dueOffsetDays == 25)
            #expect(store.activeCreditCardCycle(for: "acct_closed") == nil)
            #expect(store.activeCreditCardCycle(for: "acct_deleted") == nil)
            // Open, but never marked as a card.
            #expect(store.activeCreditCardCycle(for: "acct_untracked") == nil)

            // The closed card's config survives, so reopening restores it.
            #expect(store.creditCardCycle(for: "acct_closed")?.statementDay == 20)
        }
    }

    private func account(id: String, name: String, type: AccountType = .credit, closed: Bool = false) -> Account {
        Account(
            id: id,
            name: name,
            type: type,
            offBudget: false,
            closed: closed,
            sortOrder: 0,
            balance: 0
        )
    }
}
