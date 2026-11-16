import Foundation
import Testing
@testable import Actuali

struct BudgetStoreFreshInstallTests {
    /// Deleting the app keeps its Keychain, so a reinstall came up connected
    /// to no server and opened encrypted budgets without asking for the
    /// password. Only a launch with no trace of an earlier one clears it.
    @Test func onlyALaunchWithNoSavedStateCountsAsAFreshInstall() throws {
        let suite = "fresh-install-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(BudgetStore.isFreshInstall(defaults, hasLocalBudgets: false))

        // Updating from a build without the marker, never connected: a
        // local-only budget can still own a SimpleFIN access key.
        #expect(!BudgetStore.isFreshInstall(defaults, hasLocalBudgets: true))

        // Updating from a build without the marker: the session is live.
        defaults.set("https://budget.example.com", forKey: "serverURL")
        #expect(!BudgetStore.isFreshInstall(defaults, hasLocalBudgets: false))

        // Disconnected later, with the marker in place: not a reinstall.
        defaults.set(true, forKey: "hasLaunched")
        defaults.set("", forKey: "serverURL")
        #expect(!BudgetStore.isFreshInstall(defaults, hasLocalBudgets: false))
    }
}
