import Foundation

/// Whether the user has opted into transaction notifications (GH #27).
/// Default off — this gates notification posting only. Background refresh
/// runs regardless (fresh data on open) and iOS's per-app Background App
/// Refresh switch remains the off button for background activity.
struct TransactionNotificationSettings {

    static let key = "transactionNotificationsEnabled"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.key) }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}
