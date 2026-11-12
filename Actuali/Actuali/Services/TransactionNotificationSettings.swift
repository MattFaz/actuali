import Foundation

/// Whether the user has opted into transaction notifications (GH #27).
/// Default off — this gates notification posting only. Background refresh
/// runs regardless (fresh data on open) and iOS's per-app Background App
/// Refresh switch remains the off button for background activity.
struct TransactionNotificationSettings {
    static let key = "transactionNotificationsEnabled"
    static let includesOffBudgetKey = "transactionNotificationsIncludeOffBudget"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.key) }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }

    /// Whether off-budget (tracking) account transactions are included
    /// (GH #755). Default on, so existing opted-in users see no change.
    var includesOffBudget: Bool {
        get { defaults.object(forKey: Self.includesOffBudgetKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.includesOffBudgetKey) }
    }
}
