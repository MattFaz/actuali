import Foundation

/// Tab the app opens on at launch. Persisted to UserDefaults, defaults to Accounts.
enum StartTab: String, CaseIterable, Identifiable {
    case accounts
    case budget
    case addTransaction
    case reports

    var id: String { rawValue }

    /// Tag of the matching tab in MainTabView.
    var tabTag: Int {
        switch self {
        case .accounts: return 0
        case .budget: return 1
        case .addTransaction: return 2
        case .reports: return 3
        }
    }

    var label: String {
        switch self {
        case .accounts: return String(localized: "Accounts")
        case .budget: return String(localized: "Budget")
        case .addTransaction: return String(localized: "Add Transaction")
        case .reports: return String(localized: "Reports")
        }
    }

    static let defaultsKey = "startTab"

    static func resolved(from raw: String?) -> StartTab {
        raw.flatMap(StartTab.init(rawValue:)) ?? .accounts
    }

    static var persisted: StartTab {
        resolved(from: UserDefaults.standard.string(forKey: defaultsKey))
    }
}
