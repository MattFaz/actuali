@testable import Actuali
import Foundation
import Testing

struct CreditCardNotificationSettingsTests {
    private func makeDefaults() -> UserDefaults {
        let name = "CreditCardNotificationSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func disabledByDefault() {
        let settings = CreditCardNotificationSettings(defaults: makeDefaults())
        #expect(settings.isEnabled == false)
    }

    @Test func enablementPersistsAcrossInstances() {
        let defaults = makeDefaults()
        CreditCardNotificationSettings(defaults: defaults).isEnabled = true
        #expect(CreditCardNotificationSettings(defaults: defaults).isEnabled == true)
    }
}
