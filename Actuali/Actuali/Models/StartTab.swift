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
        label(locale: .autoupdatingCurrent)
    }

    func label(locale: Locale, bundle: Bundle = .main) -> String {
        switch self {
        case .accounts: return ReportStrings.text("Accounts", locale: locale, bundle: bundle)
        case .budget: return ReportStrings.text("Budget", locale: locale, bundle: bundle)
        case .addTransaction: return ReportStrings.text("Add Transaction", locale: locale, bundle: bundle)
        case .reports: return ReportStrings.text("Reports", locale: locale, bundle: bundle)
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
