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
        let today = DayDate(year: 2026, month: 9, day: 4)

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
        let cycle = CreditCardCycle(statementDay: 15, dueOffsetDays: 15)

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
}
