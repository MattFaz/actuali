import Foundation

/// How the Budget tab lays out its summary and category rows (actios-96wa).
/// `clean` is the card look from the App Store screenshots — category name
/// with a large Available amount and Budgeted/Spent captions. `detailed` is
/// the PWA-style table of Budgeted/Spent/Balance pill columns. `compact` adapts
/// the companion app's plain monthly table while retaining Actuali behavior.
enum BudgetDisplayStyle: String, CaseIterable {
    case clean
    case detailed
    case compact

    static let defaultsKey = "budgetDisplayStyle"

    static func persisted(in defaults: UserDefaults = .standard) -> BudgetDisplayStyle {
        guard let rawValue = defaults.string(forKey: defaultsKey) else {
            return .clean
        }
        return BudgetDisplayStyle(rawValue: rawValue) ?? .clean
    }

    var supportsGroupTotals: Bool {
        self == .detailed || self == .compact
    }
}

struct CompactBudgetViewPreferences: Equatable {
    static let showOverviewKey = "showCompactBudgetOverview"
    static let showSpentColumnKey = "showCompactSpentColumn"

    static let defaults = CompactBudgetViewPreferences(
        showOverview: true,
        showSpentColumn: false
    )

    let showOverview: Bool
    let showSpentColumn: Bool

    static func persisted(in defaults: UserDefaults = .standard) -> CompactBudgetViewPreferences {
        CompactBudgetViewPreferences(
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
