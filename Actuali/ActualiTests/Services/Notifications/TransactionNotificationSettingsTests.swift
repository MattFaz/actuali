import Foundation
import Testing
@testable import Actuali

struct TransactionNotificationSettingsTests {
    private func makeDefaults() -> UserDefaults {
        let name = "TransactionNotificationSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func disabledByDefault() {
        let settings = TransactionNotificationSettings(defaults: makeDefaults())

        #expect(settings.isEnabled == false)
    }

    @Test func enablementPersistsAcrossInstances() {
        let defaults = makeDefaults()

        TransactionNotificationSettings(defaults: defaults).isEnabled = true

        #expect(TransactionNotificationSettings(defaults: defaults).isEnabled == true)
    }

    /// Off-budget alerts stay on until the user mutes them, so existing
    /// opted-in users see no change (GH #755).
    @Test func includesOffBudgetByDefault() {
        let settings = TransactionNotificationSettings(defaults: makeDefaults())

        #expect(settings.includesOffBudget == true)
    }

    @Test func offBudgetExclusionPersistsAcrossInstances() {
        let defaults = makeDefaults()

        TransactionNotificationSettings(defaults: defaults).includesOffBudget = false

        #expect(TransactionNotificationSettings(defaults: defaults).includesOffBudget == false)
    }
}
