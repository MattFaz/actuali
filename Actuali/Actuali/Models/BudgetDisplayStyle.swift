import Foundation

/// How the Budget tab lays out its summary and category rows (actios-96wa).
/// `clean` is the card look from the App Store screenshots — category name
/// with a large Available amount and Budgeted/Spent captions. `detailed` is
/// the PWA-style table of Budgeted/Spent/Balance pill columns. `list` adapts
/// the companion app's plain monthly table while retaining Actuali behavior.
enum BudgetDisplayStyle: String, CaseIterable {
    case clean
    case detailed
    case list

    static let defaultsKey = "budgetDisplayStyle"

    static func persisted(in defaults: UserDefaults = .standard) -> BudgetDisplayStyle {
        guard let rawValue = defaults.string(forKey: defaultsKey) else {
            return .clean
        }
        return BudgetDisplayStyle(rawValue: rawValue) ?? .clean
    }

    var supportsGroupTotals: Bool {
        self == .detailed || self == .list
    }
}

struct ListBudgetViewPreferences: Equatable {
    static let showOverviewKey = "showListBudgetOverview"
    static let showSpentColumnKey = "showListSpentColumn"

    static let defaults = ListBudgetViewPreferences(
        showOverview: true,
        showSpentColumn: false
    )

    let showOverview: Bool
    let showSpentColumn: Bool

    static func persisted(in defaults: UserDefaults = .standard) -> ListBudgetViewPreferences {
        ListBudgetViewPreferences(
            showOverview: persistedBool(
                forKey: showOverviewKey,
                defaultValue: Self.defaults.showOverview,
                in: defaults
            ),
            showSpentColumn: persistedBool(
                forKey: showSpentColumnKey,
                defaultValue: Self.defaults.showSpentColumn,
                in: defaults
            )
        )
    }

    private static func persistedBool(
        forKey key: String,
        defaultValue: Bool,
        in defaults: UserDefaults
    ) -> Bool {
        defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }
}
