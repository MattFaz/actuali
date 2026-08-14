import Foundation

/// Amount condition on a schedule's rule.
enum ScheduledAmount: Equatable {
    case fixed(Int)             // cents
    case range(Int, Int)        // num1, num2 from an isbetween condition (cents)

    /// Amount a posted transaction should carry, mirroring loot-core
    /// `getScheduledAmount`: `Math.round((num1 + num2) / 2)`. JS `Math.round`
    /// rounds half toward +∞, which matters for negative cents:
    /// (-3 + -4) / 2 = -3.5 → -3, whereas Swift's `.rounded()` gives -4.
    var postAmount: Int {
        switch self {
        case .fixed(let a): return a
        case .range(let a, let b): return Int((Double(a + b) / 2 + 0.5).rounded(.down))
        }
    }
}

/// The rule's date condition: either a one-off day or a recurrence.
enum ScheduleDateCondition: Equatable {
    case fixed(DayDate)
    case recurring(RecurConfig)
    case unsupported
}

/// A schedule eligible for auto-posting, read from the synced Actual tables
/// (`schedules` + `schedules_next_date` + the linked rule's conditions).
struct Schedule {
    let id: String
    let name: String?
    /// Effective next occurrence, per loot-core's v_schedules view:
    /// `local_next_date` when `local_next_date_ts == base_next_date_ts`,
    /// otherwise `base_next_date`.
    let nextDate: DayDate
    /// `schedules_next_date.id` — target row for the advance write after posting.
    let nextDateRowId: String
    /// `schedules_next_date.base_next_date_ts` (ms epoch); the advance write
    /// sets `local_next_date_ts` to this value (loot-core setNextDate). NULL
    /// in the row stays nil here — the web posts such schedules (its
    /// v_schedules CASE falls through to base_next_date) and its advance
    /// writes a NULL local_next_date_ts, so ours must too.
    let baseNextDateTs: Int64?
    let accountId: String
    let payeeId: String?
    /// From the linked rule's `set category` action, when present. Surfaced
    /// here because the RulesEngine can't apply the rule at post time — its
    /// recurring-date condition is unsupported on iOS (see Rule.swift).
    let categoryId: String?
    /// nil when the rule has no amount condition. loot-core's
    /// `getScheduledAmount(null)` posts 0 in that case — we keep nil here and
    /// let the poster decide, rather than baking the 0 into the model.
    let amount: ScheduledAmount?
    let dateCondition: ScheduleDateCondition
}
