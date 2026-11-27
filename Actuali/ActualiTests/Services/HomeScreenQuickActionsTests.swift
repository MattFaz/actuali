import Testing
import UIKit
@testable import Actuali

@MainActor
struct HomeScreenQuickActionsTests {
    @Test func addTransactionShortcutOpensTheAddSheet() {
        let shortcut = ActualiHomeScreenShortcut.addTransaction
        #expect(ActualiSceneDelegate.isAddTransaction(shortcut))
        #expect(shortcut.localizedTitle == String(localized: "Add Transaction"))
    }

    @Test func unrelatedShortcutIsIgnored() {
        let shortcut = UIApplicationShortcutItem(
            type: "com.mfazz.Actuali.otherShortcut",
            localizedTitle: "Other"
        )
        #expect(!ActualiSceneDelegate.isAddTransaction(shortcut))
    }
}
