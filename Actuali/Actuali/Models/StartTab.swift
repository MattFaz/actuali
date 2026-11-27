import Foundation

/// Tab the app opens on at launch. Persisted to UserDefaults, defaults to Accounts.
enum StartTab: String, CaseIterable, Identifiable {
    case accounts
    case budget
    case reports

    var id: String {
        rawValue
    }

    /// Tag of the matching tab in MainTabView.
    var tabTag: Int {
        switch self {
        case .accounts: 0
        case .budget: 1
        case .reports: 3
        }
    }

    func label(locale: Locale, bundle: Bundle = .main) -> String {
        switch self {
        case .accounts: ReportStrings.text("Accounts", locale: locale, bundle: bundle)
        case .budget: ReportStrings.text("Budget", locale: locale, bundle: bundle)
        case .reports: ReportStrings.text("Reports", locale: locale, bundle: bundle)
        }
    }

    static let defaultsKey = "startTab"

    /// Anything unrecognised opens Accounts, including "addTransaction" stored
    /// back when Add was a tab.
    static func resolved(from raw: String?) -> StartTab {
        raw.flatMap(StartTab.init(rawValue:)) ?? .accounts
    }

    static var persisted: StartTab {
        resolved(from: UserDefaults.standard.string(forKey: defaultsKey))
    }
}
