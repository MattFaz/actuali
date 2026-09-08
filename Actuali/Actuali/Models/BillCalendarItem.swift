import Foundation

enum BillItemKind: Equatable, Sendable {
    case schedule(ScheduleSummary)
    case creditCard
}

/// A unified item projected onto the Bills Calendar.
///
/// Can represent either an Actual scheduled transaction occurrence or an
/// upcoming credit card payment due date from `CreditCardCycle`.
struct BillCalendarItem: Identifiable, Equatable, Sendable {
    let id: String
    let date: DayDate
    let title: String
    /// Amount in integer cents. Following Actual convention, negative represents
    /// money leaving (bills/expenses), positive represents money entering (income).
    let amount: Int
    let categoryName: String?
    let accountName: String?
    let status: ScheduleStatus
    let kind: BillItemKind
    let relativeDueText: String

    var isCreditCard: Bool {
        if case .creditCard = kind { return true }
        return false
    }

    var scheduleSummary: ScheduleSummary? {
        if case .schedule(let summary) = kind { return summary }
        return nil
    }

    /// Only the current occurrence can be posted or skipped by the schedule APIs.
    var isCurrentScheduleOccurrence: Bool {
        scheduleSummary?.nextDate == date
    }

    /// Two-digit day representation for the calendar date badge, e.g. "07".
    var dayString: String {
        String(format: "%02d", date.day)
    }

    /// Three-letter uppercase month abbreviation, e.g. "SEP".
    var monthAbbreviation: String {
        guard (1...12).contains(date.month) else { return "" }
        let symbols = DateFormatter().shortStandaloneMonthSymbols ?? []
        return symbols.indices.contains(date.month - 1)
            ? symbols[date.month - 1].uppercased()
            : ""
    }
}
