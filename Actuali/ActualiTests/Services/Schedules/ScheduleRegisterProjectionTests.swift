import Foundation
import Testing
@testable import Actuali

struct ScheduleRegisterProjectionTests {
    private let today = DayDate(year: 2026, month: 10, day: 6)

    private func schedule(
        _ id: String,
        date: DayDate?,
        accountId: String? = "account-1",
        amount: Int,
        completed: Bool = false,
        postsTransaction: Bool = true,
        sortOrder: Double? = nil
    ) -> ScheduleSummary {
        ScheduleSummary(
            id: id, name: id, ruleId: nil,
            nextDate: date, nextDateRowId: nil, baseNextDateTs: nil,
            accountId: accountId, payeeId: nil,
            amount: .fixed(amount), amountOp: .isExactly, dateOp: nil,
            dateCondition: nil, postsTransaction: postsTransaction, completed: completed,
            customUpcomingLength: nil, sortOrder: sortOrder, isCustom: false,
            conditionsJSON: nil, actionsJSON: nil
        )
    }

    @Test func accountEntriesAreDateOrderedAndCarryForwardProjectedBalances() {
        let schedules = [
            schedule("later", date: today.adding(days: 3), amount: -200),
            schedule("today-outflow", date: today, amount: -100, sortOrder: 2),
            schedule("tomorrow", date: today.adding(days: 1), amount: 500),
            schedule("today-inflow", date: today, amount: 50, sortOrder: 1),
            schedule("other-account", date: today, accountId: "account-2", amount: 1000),
            schedule("past", date: today.adding(days: -1), amount: 300),
            schedule("completed", date: today.adding(days: 1), amount: 300, completed: true),
            schedule("outside-upcoming-window", date: today.adding(days: 10), amount: 100),
            schedule("missing-date", date: nil, amount: 100),
        ]
        let statuses: [String: ScheduleStatus] = [
            "later": .upcoming,
            "today-outflow": .due,
            "tomorrow": .upcoming,
            "today-inflow": .due,
            "other-account": .due,
            "past": .missed,
            "completed": .completed,
            "outside-upcoming-window": .scheduled,
            "missing-date": .scheduled,
        ]

        let entries = ScheduleRegisterProjection.upcomingEntries(
            schedules: schedules,
            statuses: statuses,
            accountId: "account-1",
            activeAccountIds: ["account-1", "account-2"],
            startingBalance: 1000,
            today: today
        )

        #expect(entries.map(\.schedule.id) == ["later", "tomorrow", "today-outflow", "today-inflow"])
        #expect(entries.compactMap(\.runningBalance) == [1250, 1450, 950, 1050])
    }

    @Test func nonPostingSchedulesAreIncluded() {
        let schedules = [
            schedule("manual", date: today.adding(days: 1), amount: -100, postsTransaction: false),
        ]

        let entries = ScheduleRegisterProjection.upcomingEntries(
            schedules: schedules,
            statuses: ["manual": .upcoming],
            activeAccountIds: ["account-1"],
            today: today
        )

        #expect(entries.map(\.schedule.id) == ["manual"])
    }

    @Test func closedAndMissingAccountSchedulesAreExcluded() {
        let schedules = [
            schedule("posting", date: today.adding(days: 1), amount: -100),
            schedule("closed", date: today.adding(days: 2), accountId: "closed", amount: -200),
            schedule("deleted-account", date: today.adding(days: 2), accountId: "deleted", amount: -200),
            schedule("missing-account", date: today.adding(days: 3), accountId: nil, amount: -300),
        ]
        let statuses: [String: ScheduleStatus] = [
            "posting": .upcoming,
            "closed": .upcoming,
            "deleted-account": .upcoming,
            "missing-account": .upcoming,
        ]

        let entries = ScheduleRegisterProjection.upcomingEntries(
            schedules: schedules,
            statuses: statuses,
            activeAccountIds: ["account-1"],
            today: today
        )

        #expect(entries.map(\.schedule.id) == ["posting"])
    }

    @Test func paidAndScheduledStatusesAreExcluded() {
        let schedules = [
            schedule("paid", date: today.adding(days: 1), amount: -100),
            schedule("scheduled", date: today.adding(days: 2), amount: -200),
            schedule("due", date: today, amount: -300),
        ]
        let statuses: [String: ScheduleStatus] = [
            "paid": .paid,
            "scheduled": .scheduled,
            "due": .due,
        ]

        let entries = ScheduleRegisterProjection.upcomingEntries(
            schedules: schedules,
            statuses: statuses,
            activeAccountIds: ["account-1"],
            today: today
        )

        #expect(entries.map(\.schedule.id) == ["due"])
    }

    @Test func allAccountsEntriesHaveNoProjectedBalance() {
        let schedules = [
            schedule("account-2", date: today.adding(days: 1), accountId: "account-2", amount: -100),
            schedule("account-1", date: today.adding(days: 2), amount: 100),
        ]

        let entries = ScheduleRegisterProjection.upcomingEntries(
            schedules: schedules,
            statuses: ["account-2": .upcoming, "account-1": .upcoming],
            activeAccountIds: ["account-1", "account-2"],
            today: today
        )

        #expect(entries.map(\.schedule.id) == ["account-1", "account-2"])
        #expect(entries.allSatisfy { $0.runningBalance == nil })
    }
}
