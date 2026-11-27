import Foundation

/// Device-local reporting periods, using the same UTC day boundaries as transaction dates.
struct MonthStartRule: Codable, Equatable, Sendable {
    enum Adjustment: String, Codable, CaseIterable, Sendable {
        case none
        case previousWorkingDay
        case nextWorkingDay
    }

    var day = 1
    var adjustment: Adjustment = .none
    var weekendDays: Set<Int> = [1, 7]
    var holidays: Set<Date> = []

    static let calendarMonth = Self()

    var isCalendarMonth: Bool {
        day == 1 && adjustment == .none
    }

    /// Built once: anchor(containing:) runs per transaction in custom reports.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    private var calendar: Calendar {
        Self.calendar
    }

    private func move(_ date: Date, by count: Int, component: Calendar.Component) -> Date {
        calendar.date(byAdding: component, value: count, to: date)!
    }

    func start(for anchor: Date) -> Date {
        let first = calendar.dateInterval(of: .month, for: anchor)!.start
        let lastDay = calendar.range(of: .day, in: .month, for: first)!.count
        var date = move(first, by: min(max(day, 1), lastDay) - 1, component: .day)
        guard adjustment != .none, (1...7).contains(where: { !weekendDays.contains($0) }) else { return date }
        let step = adjustment == .previousWorkingDay ? -1 : 1
        while weekendDays.contains(calendar.component(.weekday, from: date)) || holidays.contains(date) {
            date = move(date, by: step, component: .day)
        }
        return date
    }

    func anchor(containing date: Date) -> Date {
        var month = calendar.dateInterval(of: .month, for: date)!.start
        while start(for: month) > date {
            month = move(month, by: -1, component: .month)
        }
        // A previous-working-day shift can bring a later anchor into this period.
        var next = move(month, by: 1, component: .month)
        while start(for: next) <= date {
            month = next
            next = move(month, by: 1, component: .month)
        }
        return month
    }

    func range(relativeTo date: Date, first: Int, last: Int) -> (Date, Date) {
        let anchor = anchor(containing: date)
        let start = start(for: move(anchor, by: first, component: .month))
        let next = self.start(for: move(anchor, by: last + 1, component: .month))
        return (start, move(next, by: -1, component: .day))
    }

    func periods(from start: Date, through end: Date) -> [ClosedRange<Date>] {
        guard start <= end else { return [] }
        var periods: [ClosedRange<Date>] = []
        var cursor = start
        while cursor <= end {
            let (_, periodEnd) = range(relativeTo: cursor, first: 0, last: 0)
            periods.append(cursor...min(end, periodEnd))
            cursor = move(periodEnd, by: 1, component: .day)
        }
        return periods
    }

    static func load(for budgetID: String?) -> Self {
        guard let budgetID, let data = UserDefaults.standard.data(forKey: defaultsKey(budgetID)) else { return .calendarMonth }
        return (try? JSONDecoder().decode(Self.self, from: data)) ?? .calendarMonth
    }

    func save(for budgetID: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey(budgetID))
    }

    private static func defaultsKey(_ budgetID: String) -> String {
        "reportMonthStartRule.\(budgetID)"
    }
}
