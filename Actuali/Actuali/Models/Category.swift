import Foundation

struct Category: Identifiable, Hashable {
    let id: String
    var name: String
    var groupId: String
    var isIncome: Bool
    var hidden: Bool
    var sortOrder: Int
}

/// A category's note, as stored in Actual's `notes` table (GH #131).
///
/// `supported` is false when the open budget file has no `notes` table at all
/// — an older snapshot, or one whose migrations haven't caught up. The UI hides
/// the note section in that case rather than offering an edit that could never
/// save. Empty `text` means "no note": Actual stores a cleared note as an empty
/// string rather than removing the row, so absent and cleared read the same.
struct CategoryNote: Equatable {
    var supported: Bool
    var text: String

    static let unsupported = CategoryNote(supported: false, text: "")

    var isEmpty: Bool { text.isEmpty }

    /// What to persist for text the user typed. Whitespace-only input clears
    /// the note instead of storing blanks that would render as an empty-looking
    /// note nobody can tell apart from none. Anything else is stored verbatim —
    /// leading indentation and blank lines inside a multi-line note are
    /// deliberate and must survive the round trip.
    static func normalizedForSave(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text
    }
}

struct CategoryGroup: Identifiable, Hashable {
    let id: String
    var name: String
    var isIncome: Bool
    var hidden: Bool
    var sortOrder: Int
    var categories: [Category]
}
