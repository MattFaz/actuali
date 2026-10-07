import Foundation

struct UpcomingScheduleEntry: Identifiable {
    let schedule: ScheduleSummary
    let date: DayDate
    let runningBalance: Int?

    var id: String { schedule.id }
}

enum ScheduleRegisterProjection {
    static func upcomingEntries(
        schedules: [ScheduleSummary],
        statuses: [String: ScheduleStatus],
        accountId: String? = nil,
        closedAccountIds: Set<String> = [],
        startingBalance: Int? = nil,
        today: DayDate = .today()
    ) -> [UpcomingScheduleEntry] {
        let upcoming = schedules.compactMap { schedule -> (schedule: ScheduleSummary, date: DayDate)? in
            guard let date = schedule.nextDate,
                  let scheduleAccountId = schedule.accountId,
                  date >= today,
                  !schedule.completed,
                  !closedAccountIds.contains(scheduleAccountId),
                  statuses[schedule.id] == .upcoming || statuses[schedule.id] == .due,
                  accountId == nil || scheduleAccountId == accountId
            else { return nil }

            return (schedule, date)
        }.sorted { first, second in
            if first.date != second.date {
                return first.date < second.date
            }
            return (first.schedule.sortOrder ?? 0) < (second.schedule.sortOrder ?? 0)
        }

        var balance = startingBalance
        return upcoming.map { item in
            if let current = balance {
                balance = current + item.schedule.postAmount
            }
            return UpcomingScheduleEntry(
                schedule: item.schedule,
                date: item.date,
                runningBalance: balance
            )
        }
    }
}
