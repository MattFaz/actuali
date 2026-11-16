import Foundation

struct UpcomingScheduleEntry: Identifiable {
    let schedule: ScheduleSummary
    let date: DayDate
    let runningBalance: Int?

    /// A recurring schedule shows once per occurrence, so the date keeps rows
    /// apart (upstream's `preview/<schedule>/<date>`).
    var id: String {
        "\(schedule.id)/\(date.iso)"
    }

    /// Only the schedule's own next date and the missed repeats before today
    /// carry its status; later occurrences are upcoming (upstream `forceUpcoming`).
    func status(in statuses: [String: ScheduleStatus], today: DayDate = .today()) -> ScheduleStatus {
        date == schedule.nextDate || date < today ? statuses[schedule.id] ?? .scheduled : .upcoming
    }
}

enum ScheduleRegisterProjection {
    static func upcomingEntries(
        schedules: [ScheduleSummary],
        statuses: [String: ScheduleStatus],
        accountId: String? = nil,
        activeAccountIds: Set<String>,
        startingBalance: Int? = nil,
        upcomingLength: String? = nil,
        today: DayDate = .today()
    ) -> [UpcomingScheduleEntry] {
        let upcoming = schedules.flatMap { schedule -> [(schedule: ScheduleSummary, date: DayDate)] in
            guard let date = schedule.nextDate,
                  let scheduleAccountId = schedule.accountId,
                  !schedule.completed,
                  activeAccountIds.contains(scheduleAccountId),
                  [.upcoming, .due, .missed].contains(statuses[schedule.id]),
                  accountId == nil || scheduleAccountId == accountId
            else { return [] }

            return occurrences(of: schedule, from: date, upcomingLength: upcomingLength, today: today)
                .map { (schedule, $0) }
        }.sorted { first, second in
            if first.date != second.date {
                return first.date < second.date
            }
            return (first.schedule.sortOrder ?? 0) < (second.schedule.sortOrder ?? 0)
        }

        // Accumulate forward, then display newest first like the transaction register.
        // Missed rows are display-only, so they neither carry nor move the balance.
        var balance = startingBalance
        return upcoming.map { item in
            if item.date < today {
                return UpcomingScheduleEntry(schedule: item.schedule, date: item.date, runningBalance: nil)
            }
            if let current = balance {
                balance = current + item.schedule.postAmount
            }
            return UpcomingScheduleEntry(
                schedule: item.schedule,
                date: item.date,
                runningBalance: balance
            )
        }.reversed()
    }

    /// Every occurrence from `nextDate` to the end of the schedule's upcoming
    /// window, as upstream `computeSchedulePreviewTransactions`.
    private static func occurrences(
        of schedule: ScheduleSummary,
        from nextDate: DayDate,
        upcomingLength: String?,
        today: DayDate
    ) -> [DayDate] {
        guard case .recurring(let config) = schedule.dateCondition else { return [nextDate] }
        let days = ScheduleUpcomingLength.days(for: schedule.customUpcomingLength ?? upcomingLength, today: today)
        let end = today.adding(days: days)
        // ponytail: missed repeats start one upcoming window back, so a schedule
        // neglected for months cannot fill the register (upstream lists them all).
        // The next date always stays because every row's actions target it.
        let floor = today.adding(days: -days)
        guard nextDate < floor else { return ScheduleRecurrence.occurrences(of: config, from: nextDate, through: end) }
        guard let start = ScheduleRecurrence.nextOccurrence(config: config, onOrAfter: floor),
              start > nextDate, start <= end
        else { return [nextDate] }
        return [nextDate] + ScheduleRecurrence.occurrences(of: config, from: start, through: end)
    }
}
