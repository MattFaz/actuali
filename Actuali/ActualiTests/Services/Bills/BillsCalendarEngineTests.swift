import Foundation
import Testing
@testable import Actuali

struct BillsCalendarEngineTests {

    @Test func leadingEmptyDaysAndMonthDayCount() {
        // September 1, 2026 is Tuesday.
        // On a Monday-first grid: Monday is 0 offset, Tuesday is 1 offset.
        let empty = BillsCalendarEngine.leadingEmptyDays(year: 2026, month: 9)
        #expect(empty == 1)

        let days = BillsCalendarEngine.daysInMonth(year: 2026, month: 9)
        #expect(days.count == 30)
        #expect(days.first?.yyyymmdd == 20260901)
        #expect(days.last?.yyyymmdd == 20260930)
    }

    @Test func relativeDueTextFormatting() {
        let today = DayDate(year: 2026, month: 9, day: 4)

        #expect(BillsCalendarEngine.relativeDueText(for: DayDate(year: 2026, month: 9, day: 4), today: today, status: .due) == "Due today")
        #expect(BillsCalendarEngine.relativeDueText(for: DayDate(year: 2026, month: 9, day: 5), today: today, status: .upcoming) == "Due tomorrow")
        #expect(BillsCalendarEngine.relativeDueText(for: DayDate(year: 2026, month: 9, day: 7), today: today, status: .upcoming) == "Due in 3 days")
        #expect(BillsCalendarEngine.relativeDueText(for: DayDate(year: 2026, month: 9, day: 3), today: today, status: .missed) == "Overdue by 1 day")
        #expect(BillsCalendarEngine.relativeDueText(for: DayDate(year: 2026, month: 9, day: 1), today: today, status: .missed) == "Overdue by 3 days")
        #expect(BillsCalendarEngine.relativeDueText(for: DayDate(year: 2026, month: 9, day: 4), today: today, status: .paid) == "Paid")
    }

    @Test func projectsSchedulesIntoMonthOccurrences() {
        let today = DayDate(year: 2026, month: 9, day: 4)

        let monthlyConfig = RecurConfig(
            frequency: .monthly,
            start: DayDate(year: 2026, month: 1, day: 15)
        )

        let recurringSchedule = ScheduleSummary(
            id: "sch-1",
            name: "Internet Bill",
            nextDate: DayDate(year: 2026, month: 9, day: 15),
            amount: .fixed(-7500),
            amountOp: .isExactly,
            dateCondition: .recurring(monthlyConfig),
            postsTransaction: true,
            completed: false,
            isCustom: false
        )

        let fixedSchedule = ScheduleSummary(
            id: "sch-2",
            name: "Annual Domain",
            nextDate: DayDate(year: 2026, month: 9, day: 22),
            amount: .fixed(-2000),
            amountOp: .isExactly,
            dateCondition: .fixed(DayDate(year: 2026, month: 9, day: 22)),
            postsTransaction: false,
            completed: false,
            isCustom: false
        )

        let items = BillsCalendarEngine.itemsForSchedules(
            schedules: [recurringSchedule, fixedSchedule],
            statuses: ["sch-1": .upcoming, "sch-2": .upcoming],
            accounts: [],
            payees: [],
            categoryGroups: [],
            year: 2026,
            month: 9,
            today: today
        )

        #expect(items.count == 2)
        #expect(items[0].title == "Internet Bill")
        #expect(items[0].date == DayDate(year: 2026, month: 9, day: 15))
        #expect(items[0].amount == -7500)
        #expect(items[0].relativeDueText == "Due in 11 days")

        #expect(items[1].title == "Annual Domain")
        #expect(items[1].date == DayDate(year: 2026, month: 9, day: 22))
        #expect(items[1].amount == -2000)
    }

    @Test func computesSummaryTotalsAndFilter() {

        let item1 = BillCalendarItem(
            id: "1",
            date: DayDate(year: 2026, month: 9, day: 7),
            title: "Utility",
            amount: -12500,
            categoryName: "Bills",
            accountName: "Checking",
            status: .upcoming,
            kind: .schedule(ScheduleSummary(
                id: "1",
                amountOp: .isExactly,
                postsTransaction: true,
                completed: false,
                isCustom: false
            )),
            relativeDueText: "Due in 3 days"
        )

        let item2 = BillCalendarItem(
            id: "2",
            date: DayDate(year: 2026, month: 9, day: 1),
            title: "Gym",
            amount: -5000,
            categoryName: "Fitness",
            accountName: "Checking",
            status: .missed,
            kind: .schedule(ScheduleSummary(
                id: "2",
                amountOp: .isExactly,
                postsTransaction: true,
                completed: false,
                isCustom: false
            )),
            relativeDueText: "Overdue by 3 days"
        )

        let item3 = BillCalendarItem(
            id: "3",
            date: DayDate(year: 2026, month: 9, day: 3),
            title: "Streaming",
            amount: -1500,
            categoryName: "Entertainment",
            accountName: "Checking",
            status: .paid,
            kind: .schedule(ScheduleSummary(
                id: "3",
                amountOp: .isExactly,
                postsTransaction: true,
                completed: false,
                isCustom: false
            )),
            relativeDueText: "Paid"
        )

        let summary = BillsCalendarEngine.summarize(items: [item1, item2, item3])
        #expect(summary.upcomingTotal == 12500)
        #expect(summary.overdueTotal == 5000)
        #expect(summary.paidTotal == 1500)
        #expect(summary.clearedCount == 1)
        #expect(summary.totalCount == 3)

        let upcomingOnly = BillsCalendarEngine.filter(items: [item1, item2, item3], filter: .upcoming, selectedDate: nil)
        #expect(upcomingOnly.map(\.id) == ["1"])

        let overdueOnly = BillsCalendarEngine.filter(items: [item1, item2, item3], filter: .overdue, selectedDate: nil)
        #expect(overdueOnly.map(\.id) == ["2"])

        let paidOnly = BillsCalendarEngine.filter(items: [item1, item2, item3], filter: .paid, selectedDate: nil)
        #expect(paidOnly.map(\.id) == ["3"])

        let dateFilter = BillsCalendarEngine.filter(items: [item1, item2, item3], filter: .all, selectedDate: DayDate(year: 2026, month: 9, day: 7))
        #expect(dateFilter.map(\.id) == ["1"])
    }

    @Test func projectsCreditCardBillsIntoMonth() {
        let today = DayDate(year: 2026, month: 9, day: 4)
        let account = Account(
            id: "acc-cc",
            name: "Amex Gold",
            type: .credit,
            offBudget: false,
            closed: false,
            sortOrder: 0,
            balance: -45000 // owes $450.00
        )
        // Statement day 15, due offset 15 days -> statement Aug 15 -> due Aug 30 (before today) -> next statement Sept 15 -> due Sept 30
        let cycle = CreditCardCycle(statementDay: 15, paymentDue: .daysAfter(15))

        let items = BillsCalendarEngine.itemsForCreditCards(
            accounts: [account],
            cycles: ["acc-cc": cycle],
            year: 2026,
            month: 9,
            today: today
        )

        #expect(items.count == 1)
        #expect(items[0].title == "Amex Gold")
        #expect(items[0].amount == -45000)
        #expect(items[0].date == DayDate(year: 2026, month: 9, day: 30))
        #expect(items[0].isCreditCard == true)
    }

    @Test func skipWeekendAndBeforeSolveModeDoesNotLoopInfinitely() {
        // September 6, 2026 is Sunday.
        // With skipWeekend: true and weekendSolveMode: "before", the occurrence shifts to Friday, Sept 4.
        let config = RecurConfig(
            frequency: .monthly,
            start: DayDate(year: 2026, month: 9, day: 6),
            skipWeekend: true,
            weekendSolveMode: "before"
        )
        let schedule = ScheduleSummary(
            id: "sch-weekend",
            name: "Weekend Bill",
            nextDate: DayDate(year: 2026, month: 9, day: 4),
            amount: .fixed(-5000),
            amountOp: .isExactly,
            dateCondition: .recurring(config),
            postsTransaction: true,
            completed: false,
            isCustom: false
        )

        let items = BillsCalendarEngine.itemsForSchedules(
            schedules: [schedule],
            statuses: ["sch-weekend": .upcoming],
            accounts: [],
            payees: [],
            categoryGroups: [],
            year: 2026,
            month: 9,
            today: DayDate(year: 2026, month: 9, day: 1)
        )

        #expect(items.count == 1)
        #expect(items[0].date == DayDate(year: 2026, month: 9, day: 4))
    }

    @Test func exhaustedBoundedRecurrenceTerminates() {
        // Bounded recurrence that ran out after 1 occurrence in August 2026.
        let config = RecurConfig(
            frequency: .monthly,
            start: DayDate(year: 2026, month: 8, day: 10),
            endMode: "after_n_occurrences",
            endOccurrences: 1
        )
        let schedule = ScheduleSummary(
            id: "sch-bounded",
            name: "Trial Subscription",
            nextDate: DayDate(year: 2026, month: 8, day: 10),
            amount: .fixed(-1000),
            amountOp: .isExactly,
            dateCondition: .recurring(config),
            postsTransaction: true,
            completed: false,
            isCustom: false
        )

        let items = BillsCalendarEngine.itemsForSchedules(
            schedules: [schedule],
            statuses: [:],
            accounts: [],
            payees: [],
            categoryGroups: [],
            year: 2026,
            month: 9,
            today: DayDate(year: 2026, month: 9, day: 1)
        )

        #expect(items.isEmpty)
    }

    @Test func recurringScheduleProjectsInPastMonth() {
        let monthlyConfig = RecurConfig(
            frequency: .monthly,
            start: DayDate(year: 2026, month: 1, day: 15)
        )
        let schedule = ScheduleSummary(
            id: "sch-history",
            name: "Cloud Storage",
            nextDate: DayDate(year: 2026, month: 9, day: 15),
            amount: .fixed(-999),
            amountOp: .isExactly,
            dateCondition: .recurring(monthlyConfig),
            postsTransaction: true,
            completed: false,
            isCustom: false
        )

        // Viewing August 2026 even though nextDate is in September 2026
        let items = BillsCalendarEngine.itemsForSchedules(
            schedules: [schedule],
            statuses: [:],
            accounts: [],
            payees: [],
            categoryGroups: [],
            year: 2026,
            month: 8,
            today: DayDate(year: 2026, month: 9, day: 4)
        )

        #expect(items.count == 1)
        #expect(items[0].date == DayDate(year: 2026, month: 8, day: 15))
        #expect(items[0].status == .missed)
    }

    @Test func paidHistoricalOccurrenceKeepsItsPaidStatus() {
        let config = RecurConfig(
            frequency: .monthly,
            start: DayDate(year: 2026, month: 8, day: 15)
        )
        let schedule = ScheduleSummary(
            id: "sch-paid-history",
            name: "Cloud Storage",
            nextDate: DayDate(year: 2026, month: 9, day: 15),
            amount: .fixed(-999),
            amountOp: .isExactly,
            dateCondition: .recurring(config),
            postsTransaction: true,
            completed: false,
            isCustom: false
        )

        let items = BillsCalendarEngine.itemsForSchedules(
            schedules: [schedule],
            statuses: [:],
            paymentDates: ["sch-paid-history": [DayDate(year: 2026, month: 8, day: 15)]],
            accounts: [],
            payees: [],
            categoryGroups: [],
            year: 2026,
            month: 8,
            today: DayDate(year: 2026, month: 9, day: 4)
        )

        #expect(items.map(\.status) == [.paid])
    }

    @Test func approximateHistoricalOccurrenceAcceptsAnEarlyPayment() {
        let config = RecurConfig(frequency: .monthly, start: DayDate(year: 2026, month: 8, day: 15))
        let schedule = ScheduleSummary(
            id: "sch-early-payment",
            nextDate: DayDate(year: 2026, month: 9, day: 15),
            amountOp: .isExactly,
            dateOp: "isapprox",
            dateCondition: .recurring(config),
            postsTransaction: false,
            completed: false,
            isCustom: false
        )

        let items = BillsCalendarEngine.itemsForSchedules(
            schedules: [schedule], statuses: [:],
            paymentDates: ["sch-early-payment": [DayDate(year: 2026, month: 8, day: 13)]],
            accounts: [], payees: [], categoryGroups: [], year: 2026, month: 8,
            today: DayDate(year: 2026, month: 9, day: 4)
        )

        #expect(items.map(\.status) == [.paid])
    }

    @Test func historicalOccurrenceAcceptsALatePaymentBeforeTheNextOccurrence() {
        let config = RecurConfig(frequency: .monthly, start: DayDate(year: 2026, month: 8, day: 15))
        let schedule = ScheduleSummary(
            id: "sch-late-payment",
            nextDate: DayDate(year: 2026, month: 9, day: 15),
            amountOp: .isExactly,
            dateCondition: .recurring(config),
            postsTransaction: true,
            completed: false,
            isCustom: false
        )

        let items = BillsCalendarEngine.itemsForSchedules(
            schedules: [schedule], statuses: [:],
            paymentDates: ["sch-late-payment": [DayDate(year: 2026, month: 8, day: 20)]],
            accounts: [], payees: [], categoryGroups: [], year: 2026, month: 8,
            today: DayDate(year: 2026, month: 9, day: 4)
        )

        #expect(items.map(\.status) == [.paid])
    }

    @Test func onlyTheCurrentOccurrenceAllowsScheduleActions() {
        let config = RecurConfig(
            frequency: .monthly,
            start: DayDate(year: 2026, month: 9, day: 15)
        )
        let schedule = ScheduleSummary(
            id: "sch-current",
            nextDate: DayDate(year: 2026, month: 9, day: 15),
            amountOp: .isExactly,
            dateCondition: .recurring(config),
            postsTransaction: true,
            completed: false,
            isCustom: false
        )

        let current = BillCalendarItem(
            id: "current", date: DayDate(year: 2026, month: 9, day: 15), title: "",
            amount: 0, categoryName: nil, accountName: nil, status: .upcoming,
            kind: .schedule(schedule), relativeDueText: ""
        )
        let future = BillCalendarItem(
            id: "future", date: DayDate(year: 2026, month: 10, day: 15), title: "",
            amount: 0, categoryName: nil, accountName: nil, status: .upcoming,
            kind: .schedule(schedule), relativeDueText: ""
        )

        #expect(current.isCurrentScheduleOccurrence)
        #expect(!future.isCurrentScheduleOccurrence)
    }

    @Test func creditCardCyclesProjectPerNavigatedMonth() {
        let today = DayDate(year: 2026, month: 9, day: 4)
        let account = Account(
            id: "acc-cc",
            name: "Visa Signature",
            type: .credit,
            offBudget: false,
            closed: false,
            sortOrder: 0,
            balance: -25000
        )
        let cycle = CreditCardCycle(statementDay: 15, paymentDue: .daysAfter(15))

        let augustItems = BillsCalendarEngine.itemsForCreditCards(
            accounts: [account],
            cycles: ["acc-cc": cycle],
            year: 2026,
            month: 8,
            today: today
        )
        #expect(augustItems.count == 1)
        #expect(augustItems[0].date == DayDate(year: 2026, month: 8, day: 30))
        #expect(augustItems[0].status == .missed)

        let octoberItems = BillsCalendarEngine.itemsForCreditCards(
            accounts: [account],
            cycles: ["acc-cc": cycle],
            year: 2026,
            month: 10,
            today: today
        )
        #expect(octoberItems.count == 1)
        #expect(octoberItems[0].date == DayDate(year: 2026, month: 10, day: 30))
        #expect(octoberItems[0].status == .upcoming)
    }
}
