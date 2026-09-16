import Foundation

/// Presets for the transaction lists' status filter strip (GH #439), modeled
/// on the Budget tab's category chips. `cleared` means cleared-but-not-
/// reconciled on purpose: with `uncleared` and `reconciled` the three status
/// chips partition the list, matching the row's status dot. `uncategorized`
/// is the same pseudo-account filter the Uncategorized list uses.
enum TransactionStatusFilter: String, CaseIterable, Identifiable {
    case all
    case uncategorized
    case uncleared
    case cleared
    case reconciled

    var id: String { rawValue }

    /// Chip label. Reuses the keys the row status dot and the Uncategorized
    /// list already localize, so the chips ship in every existing language.
    func label(locale: Locale = .autoupdatingCurrent, bundle: Bundle = .main) -> String {
        ReportStrings.text(key, locale: locale, bundle: bundle)
    }

    var key: String {
        switch self {
        case .all: return "All"
        case .uncategorized: return "Uncategorized"
        case .uncleared: return "Uncleared"
        case .cleared: return "Cleared"
        case .reconciled: return "Reconciled"
        }
    }

    static let defaultsKey = "transactionStatusFilter"
    static let stripVisibilityDefaultsKey = "showTransactionStatusFilters"

    static func resolved(from raw: String?) -> TransactionStatusFilter {
        raw.flatMap(TransactionStatusFilter.init(rawValue:)) ?? .all
    }
}
