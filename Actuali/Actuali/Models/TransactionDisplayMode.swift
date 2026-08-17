import Foundation

enum TransactionDisplayMode: String, CaseIterable, Identifiable {
    case flat
    case groupedByDate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flat: return "Flat List"
        case .groupedByDate: return "Grouped by Date"
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
