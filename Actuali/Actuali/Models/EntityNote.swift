import Foundation

/// The note attached to one row of the budget, as stored in Actual's `notes`
/// table — categories (GH #131) and accounts (GH #198) alike. The table is
/// keyed by the annotated row's own id, so one model covers both rather than a
/// per-entity copy that could drift.
///
/// `supported` is false when the open budget file has no `notes` table at all
/// — an older snapshot, or one whose migrations haven't caught up. The UI hides
/// the note affordance in that case rather than offering an edit that could
/// never save. Empty `text` means "no note": Actual stores a cleared note as an
/// empty string rather than removing the row, so absent and cleared read the
/// same.
struct EntityNote: Equatable {
    var supported: Bool
    var text: String

    static let unsupported = EntityNote(supported: false, text: "")

    var isEmpty: Bool { text.isEmpty }

    /// What to persist for text the user typed. Whitespace-only input clears
    /// the note instead of storing blanks that would render as an empty-looking
    /// note nobody can tell apart from none. Anything else is stored verbatim —
    /// leading indentation and blank lines inside a multi-line note are
    /// deliberate and must survive the round trip.
    static func normalizedForSave(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text
    }

    /// The `notes.id` an account's note lives at.
    ///
    /// Accounts are the exception to "keyed by the row's own id": Actual
    /// prefixes them (`account-${account.id}` in desktop-client's account
    /// Header, sidebar Account, AccountMenuModal and mobile AccountPage), while
    /// categories and category groups use the bare id. Reading or writing the
    /// unprefixed id would put Actuali's account notes somewhere Actual never
    /// looks — invisible in both directions.
    static func accountNoteId(_ accountId: String) -> String {
        "account-\(accountId)"
    }
}
