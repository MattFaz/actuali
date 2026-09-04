import Foundation

/// Whether the user has opted into credit card payment due date notifications.
/// When enabled, local notifications are scheduled at 7, 5, 3, and 1 days before
/// the payment due date if the card has an unpaid balance.
struct CreditCardNotificationSettings {
    static let key = "creditCardDueNotificationsEnabled"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.key) }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}
