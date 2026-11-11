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

    /// Only the schedule's own next date carries its status; later occurrences
    /// are always upcoming (upstream `forceUpcoming`).
    func status(in statuses: [String: ScheduleStatus]) -> ScheduleStatus {
        date == schedule.nextDate ? statuses[schedule.id] ?? .scheduled : .upcoming
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
                  date >= today,
                  !schedule.completed,
                  activeAccountIds.contains(scheduleAccountId),
                  statuses[schedule.id] == .upcoming || statuses[schedule.id] == .due,
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
        let end = today.adding(days: ScheduleUpcomingLength.days(
            for: schedule.customUpcomingLength ?? upcomingLength, today: today
        ))
        return ScheduleRecurrence.occurrences(of: config, from: nextDate, through: end)
    }
}
