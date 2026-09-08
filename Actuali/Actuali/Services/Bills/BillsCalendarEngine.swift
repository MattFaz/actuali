import Foundation

/// Filter mode for the Bills Calendar list.
enum BillFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case upcoming = "Upcoming"
    case overdue = "Overdue"
    case paid = "Paid"

    var id: String { rawValue }
    var label: String { String(localized: String.LocalizationValue(rawValue)) }
}

/// Tab switcher between Recurring Schedules and Credit Card Bills.
enum BillsTabMode: String, CaseIterable, Identifiable, Sendable {
    case recurring = "Recurring"
    case cardBills = "Card Bills"

    var id: String { rawValue }
    var label: String { String(localized: String.LocalizationValue(rawValue)) }
}

/// Month cashflow summary for the bills calendar header.
struct BillsMonthSummary: Equatable, Sendable {
    let upcomingTotal: Int // cents
    let overdueTotal: Int  // cents
    let paidTotal: Int     // cents
    let clearedCount: Int
    let totalCount: Int
}

/// Pure functions for generating calendar grid cells, occurrences, and summary statistics.
enum BillsCalendarEngine: Sendable {


    /// Number of blank leading cells in a Monday-first monthly calendar grid.
    /// In `DayDate`, 1 = Sunday, 2 = Monday ... 7 = Saturday.
    static func leadingEmptyDays(year: Int, month: Int) -> Int {
        let firstDay = DayDate(year: year, month: month, day: 1)
        return (firstDay.weekday + 5) % 7
    }

    /// Days in the specified month (1...28/29/30/31).
    static func daysInMonth(year: Int, month: Int) -> [DayDate] {
        let count = DayDate.lastDay(year: year, month: month)
        return (1...count).map { DayDate(year: year, month: month, day: $0) }
    }

    /// Formats relative due text, e.g. "Due in 3 days", "Due today", "Overdue by 2 days", "Paid".
    static func relativeDueText(for date: DayDate, today: DayDate = .today(), status: ScheduleStatus) -> String {
        if status == .paid || status == .completed {
            return String(localized: "Paid")
        }
        let diff = today.days(until: date)
        if diff < 0 {
            let daysAgo = abs(diff)
            return daysAgo == 1
                ? String(localized: "Overdue by 1 day")
                : String(format: String(localized: "Overdue by %lld days"), Int64(daysAgo))
        } else if diff == 0 {
            return String(localized: "Due today")
        } else if diff == 1 {
            return String(localized: "Due tomorrow")
        } else {
            return String(format: String(localized: "Due in %lld days"), Int64(diff))
        }
    }

    /// Projects recurring schedules into `BillCalendarItem`s for the specified month.
    static func itemsForSchedules(
        schedules: [ScheduleSummary],
        statuses: [String: ScheduleStatus],
        paymentDates: [String: Set<DayDate>] = [:],
        accounts: [Account],
        payees: [Payee],
        categoryGroups: [CategoryGroup],
        year: Int,
        month: Int,
        today: DayDate = .today()
    ) -> [BillCalendarItem] {
        let monthStart = DayDate(year: year, month: month, day: 1)
        let monthEnd = DayDate(year: year, month: month, day: DayDate.lastDay(year: year, month: month))

        var items: [BillCalendarItem] = []

        let accountMap = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
        let payeeMap = Dictionary(uniqueKeysWithValues: payees.map { ($0.id, $0.name) })
        let categoryMap = Dictionary(uniqueKeysWithValues: categoryGroups.flatMap(\.categories).map { ($0.id, $0.name) })

        for schedule in schedules {
            let title = schedule.name
                ?? schedule.payeeId.flatMap { payeeMap[$0] }
                ?? String(localized: "Scheduled Transaction")
            let accountName = schedule.accountId.flatMap { accountMap[$0] }
            let categoryName = schedule.categoryId.flatMap { categoryMap[$0] }
            let baseStatus = statuses[schedule.id] ?? (schedule.completed ? .completed : .scheduled)

            if schedule.completed {
                // Completed schedules only show if their recorded nextDate fell in this month
                if let next = schedule.nextDate, next.year == year, next.month == month {
                    items.append(
                        BillCalendarItem(
                            id: "\(schedule.id)_\(next.yyyymmdd)",
                            date: next,
                            title: title,
                            amount: schedule.postAmount,
                            categoryName: categoryName,
                            accountName: accountName,
                            status: .completed,
                            kind: .schedule(schedule),
                            relativeDueText: String(localized: "Completed")
                        )
                    )
                }
                continue
            }

            // Uncompleted schedules:
            switch schedule.dateCondition {
            case .recurring(let config):
                // If nextDate is explicitly set and falls in the month, include it
                var occurrenceDates: Set<DayDate> = []

                if let next = schedule.nextDate, next.year == year, next.month == month {
                    occurrenceDates.insert(next)
                }
                occurrenceDates.formUnion(
                    ScheduleRecurrence.upcomingDates(for: config, count: 31, from: monthStart)
                        .filter { $0 >= monthStart && $0 <= monthEnd }
                )

                let sortedDates = occurrenceDates.sorted()
                for (index, date) in sortedDates.enumerated() {
                    let itemStatus: ScheduleStatus
                    if date == schedule.nextDate {
                        itemStatus = baseStatus
                    } else if paymentDates[schedule.id]?.contains(where: { paymentDate in
                        let matchStart = ScheduleStatusCalculator.occurrenceMatchStartDate(
                            nextDate: date,
                            dateOp: schedule.dateOp,
                            postsTransaction: schedule.postsTransaction
                        )
                        let nextDate = sortedDates.dropFirst(index + 1).first
                            ?? ScheduleRecurrence.nextOccurrence(config: config, onOrAfter: date.adding(days: 1))
                        let nextMatchStart = nextDate.flatMap { next in
                            next > date ? ScheduleStatusCalculator.occurrenceMatchStartDate(
                                nextDate: next,
                                dateOp: schedule.dateOp,
                                postsTransaction: schedule.postsTransaction
                            ) : nil
                        }
                        return paymentDate >= matchStart && (nextMatchStart.map { paymentDate < $0 } ?? true)
                    }) == true {
                        itemStatus = .paid
                    } else if date < today {
                        itemStatus = .missed
                    } else if date == today {
                        itemStatus = .due
                    } else {
                        itemStatus = .upcoming
                    }

                    items.append(
                        BillCalendarItem(
                            id: "\(schedule.id)_\(date.yyyymmdd)",
                            date: date,
                            title: title,
                            amount: schedule.postAmount,
                            categoryName: categoryName,
                            accountName: accountName,
                            status: itemStatus,
                            kind: .schedule(schedule),
                            relativeDueText: relativeDueText(for: date, today: today, status: itemStatus)
                        )
                    )
                }

            case .fixed(let day):
                if day.year == year, day.month == month {
                    items.append(
                        BillCalendarItem(
                            id: "\(schedule.id)_\(day.yyyymmdd)",
                            date: day,
                            title: title,
                            amount: schedule.postAmount,
                            categoryName: categoryName,
                            accountName: accountName,
                            status: baseStatus,
                            kind: .schedule(schedule),
                            relativeDueText: relativeDueText(for: day, today: today, status: baseStatus)
                        )
                    )
                }

            case .unsupported, nil:
                if let next = schedule.nextDate, next.year == year, next.month == month {
                    items.append(
                        BillCalendarItem(
                            id: "\(schedule.id)_\(next.yyyymmdd)",
                            date: next,
                            title: title,
                            amount: schedule.postAmount,
                            categoryName: categoryName,
                            accountName: accountName,
                            status: baseStatus,
                            kind: .schedule(schedule),
                            relativeDueText: relativeDueText(for: next, today: today, status: baseStatus)
                        )
                    )
                }
            }
        }

        return items.sorted { $0.date < $1.date }
    }

    /// Projects credit card statement and payment due dates into `BillCalendarItem`s for the month.
    static func itemsForCreditCards(
        accounts: [Account],
        cycles: [String: CreditCardCycle],
        year: Int,
        month: Int,
        today: DayDate = .today()
    ) -> [BillCalendarItem] {
        var items: [BillCalendarItem] = []

        for account in accounts where !account.closed {
            guard let cycle = cycles[account.id] else { continue }
            let dueDate = cycle.upcomingDueDate(for: DayDate(year: year, month: month, day: 1))

            // Include if the payment due date is in this month
            if dueDate.year == year, dueDate.month == month {
                // Actual represents credit card balances as negative when owed.
                // An amount owed is shown as a positive bill to pay (or negative outflow).
                let balanceOwed = max(0, -account.balance)
                let status: ScheduleStatus
                if balanceOwed == 0 {
                    status = .paid
                } else if dueDate < today {
                    status = .missed
                } else if dueDate == today {
                    status = .due
                } else {
                    status = .upcoming
                }

                items.append(
                    BillCalendarItem(
                        id: "cc_\(account.id)_\(dueDate.yyyymmdd)",
                        date: dueDate,
                        title: account.name,
                        amount: -balanceOwed, // Represented as negative outflow/bill
                        categoryName: String(localized: "Credit Card Payment"),
                        accountName: account.name,
                        status: status,
                        kind: .creditCard,
                        relativeDueText: balanceOwed == 0 ? String(localized: "Paid / Zero Balance") : relativeDueText(for: dueDate, today: today, status: status)
                    )
                )
            }
        }

        return items.sorted { $0.date < $1.date }
    }

    /// Computes month cashflow totals and cleared count.
    static func summarize(items: [BillCalendarItem]) -> BillsMonthSummary {
        var upcoming = 0
        var overdue = 0
        var paid = 0
        var cleared = 0

        for item in items {
            let absAmt = abs(item.amount)
            switch item.status {
            case .paid, .completed:
                paid += absAmt
                cleared += 1
            case .missed:
                overdue += absAmt
            case .due, .upcoming, .scheduled:
                upcoming += absAmt
            }
        }

        return BillsMonthSummary(
            upcomingTotal: upcoming,
            overdueTotal: overdue,
            paidTotal: paid,
            clearedCount: cleared,
            totalCount: items.count
        )
    }

    /// Filters items by the selected filter pill and optional selected date.
    static func filter(
        items: [BillCalendarItem],
        filter: BillFilter,
        selectedDate: DayDate?
    ) -> [BillCalendarItem] {
        items.filter { item in
            if let selectedDate, item.date != selectedDate {
                return false
            }
            switch filter {
            case .all:
                return true
            case .upcoming:
                return item.status == .upcoming || item.status == .due || item.status == .scheduled
            case .overdue:
                return item.status == .missed
            case .paid:
                return item.status == .paid || item.status == .completed
            }
        }
    }
}
