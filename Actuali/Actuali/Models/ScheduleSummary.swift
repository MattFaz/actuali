import Foundation

/// How a schedule's amount is matched, mirroring the rule condition's `op`.
/// Drives the list's amount prefix and the editor's operator picker.
enum ScheduleAmountOp: String, Hashable, CaseIterable {
    case isExactly = "is"
    case isApprox = "isapprox"
    case isBetween = "isbetween"

    var label: String {
        switch self {
        case .isExactly: "is exactly"
        case .isApprox: "is approximately"
        case .isBetween: "is between"
        }
    }
}

/// A schedule as shown on the schedules screen.
///
/// Wider than `Schedule` (the auto-posting projection): this includes completed
/// and manual schedules, and keeps the raw rule JSON so an edit can merge into
/// the existing rule instead of overwriting conditions it doesn't understand.
///
/// Almost every field is optional because a schedule can be structurally broken
/// — a missing rule or next-date row after a bad sync — and a broken schedule
/// still has to be listed, or it could never be repaired or deleted from the
/// phone.
struct ScheduleSummary: Identifiable, Equatable {
    let id: String
    var name: String?
    var ruleId: String?

    /// Effective next occurrence, per loot-core's `v_schedules` CASE.
    var nextDate: DayDate?
    /// `schedules_next_date.id` — the row a next-date write targets.
    var nextDateRowId: String?
    var baseNextDateTs: Int64?

    var accountId: String?
    var payeeId: String?
    var amount: ScheduledAmount?
    var amountOp: ScheduleAmountOp
    /// The date condition's raw op (`is` / `isapprox`), needed by the
    /// occurrence-match lookback rule.
    var dateOp: String?
    var dateCondition: ScheduleDateCondition?

    var postsTransaction: Bool
    var completed: Bool
    var customUpcomingLength: String?
    var sortOrder: Double?

    /// The rule carries conditions or actions beyond the four a schedule owns
    /// — the web's "edit as rule" case. Surfaced so the UI can warn that an
    /// edit here won't expose everything the rule does. M3 preserves these on
    /// update; they are never dropped.
    var isCustom: Bool

    /// Raw rule JSON, kept verbatim for the merge-on-update path (M3).
    var conditionsJSON: String?
    var actionsJSON: String?

    var isRecurring: Bool {
        if case .recurring = dateCondition { return true }
        return false
    }

    /// What a posted transaction would carry. `nil` amount posts 0, matching
    /// loot-core `getScheduledAmount(null)`.
    var postAmount: Int { amount?.postAmount ?? 0 }
}
