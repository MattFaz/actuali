import Foundation

/// What tapping a row in the Uncategorized list opens (GH #260). Freshly
/// imported transactions often need the payee fixed as well as the category,
/// and the editor already carries a category field, so it can be the faster
/// triage stop. Defaults to the category picker to keep the quick-tap flow.
enum UncategorizedTapAction: String, CaseIterable, Identifiable {
    case categoryPicker
    case transactionEditor

    var id: String { rawValue }

    var label: String {
        switch self {
        case .categoryPicker: return "Category Picker"
        case .transactionEditor: return "Transaction Editor"
        }
    }

    static let defaultsKey = "uncategorizedTapAction"

    static func resolved(from raw: String?) -> UncategorizedTapAction {
        raw.flatMap(UncategorizedTapAction.init(rawValue:)) ?? .categoryPicker
    }

    static var persisted: UncategorizedTapAction {
        resolved(from: UserDefaults.standard.string(forKey: defaultsKey))
    }
}
