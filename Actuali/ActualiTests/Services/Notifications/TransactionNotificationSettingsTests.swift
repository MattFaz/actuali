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

}
