import Foundation

enum TransactionDisplayMode: String, CaseIterable, Identifiable {
    case flat
    case groupedByDate

    var id: String { rawValue }

    func label(locale: Locale, bundle: Bundle = .main) -> String {
        switch self {
        case .flat: return ReportStrings.text("Flat List", locale: locale, bundle: bundle)
        case .groupedByDate: return ReportStrings.text("Grouped by Date", locale: locale, bundle: bundle)
        }
    }

    static let defaultsKey = "transactionDisplayMode"

    static func resolved(from raw: String?) -> TransactionDisplayMode {
        raw.flatMap(TransactionDisplayMode.init(rawValue:)) ?? .flat
    }

    static var persisted: TransactionDisplayMode {
        resolved(from: UserDefaults.standard.string(forKey: defaultsKey))
    }
}
