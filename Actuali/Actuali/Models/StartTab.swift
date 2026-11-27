import Foundation

/// Tab the app opens on at launch. Persisted to UserDefaults, defaults to Accounts.
enum StartTab: String, CaseIterable, Identifiable {
    case accounts
    case budget
    case addTransaction
    case reports

    var id: String {
        rawValue
    }

    /// Tag of the matching tab in MainTabView.
    var tabTag: Int {
        switch self {
        case .accounts: 0
        case .budget: 1
        case .addTransaction: 2
        case .reports: 3
        }
    }

    /// Budget, Accounts and More always stay in the tab bar.
    var isHideable: Bool {
        self == .addTransaction || self == .reports
    }

    func label(locale: Locale, bundle: Bundle = .main) -> String {
        switch self {
        case .accounts: ReportStrings.text("Accounts", locale: locale, bundle: bundle)
        case .budget: ReportStrings.text("Budget", locale: locale, bundle: bundle)
        case .addTransaction: ReportStrings.text("Add Transaction", locale: locale, bundle: bundle)
        case .reports: ReportStrings.text("Reports", locale: locale, bundle: bundle)
        }
    }

    static let defaultsKey = "startTab"

    static func resolved(from raw: String?) -> StartTab {
        raw.flatMap(StartTab.init(rawValue:)) ?? .accounts
    }

    static var persisted: StartTab {
        resolved(from: UserDefaults.standard.string(forKey: defaultsKey))
    }

    static let hiddenDefaultsKey = "hiddenTabs"

    /// Unknown and non-hideable values are dropped, so a stale or edited
    /// default can never remove Budget, Accounts or More.
    static func hidden(from raw: [String]?) -> Set<StartTab> {
        Set((raw ?? []).compactMap(StartTab.init(rawValue:)).filter(\.isHideable))
    }

    static var persistedHidden: Set<StartTab> {
        hidden(from: UserDefaults.standard.stringArray(forKey: hiddenDefaultsKey))
    }

    /// A hidden page can't be the one the app opens on, so it falls back to Accounts.
    static func effective(start: StartTab, hidden: Set<StartTab>) -> StartTab {
        hidden.contains(start) ? .accounts : start
    }

    /// The page to open on at launch and to return to after Cancel in the add flow.
    static var persistedEffective: StartTab {
        effective(start: persisted, hidden: persistedHidden)
    }

    /// What the Start Page picker offers.
    static func startPageOptions(hidden: Set<StartTab>) -> [StartTab] {
        allCases.filter { !hidden.contains($0) }
    }
}
