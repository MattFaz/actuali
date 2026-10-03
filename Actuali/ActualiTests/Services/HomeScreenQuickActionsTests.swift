import UIKit
import Testing
@testable import Actuali

@MainActor
struct HomeScreenQuickActionsTests {
    @Test func addTransactionShortcutSelectsAddTab() {
        let shortcut = UIApplicationShortcutItem(
            type: ActualiHomeScreenShortcut.addTransactionType,
            localizedTitle: "Add Transaction"
        )
        #expect(ActualiSceneDelegate.tab(for: shortcut) == StartTab.addTransaction.tabTag)
    }

    @Test func unrelatedShortcutIsIgnored() {
        let shortcut = UIApplicationShortcutItem(
            type: "com.mfazz.Actuali.otherShortcut",
            localizedTitle: "Other"
        )
        #expect(ActualiSceneDelegate.tab(for: shortcut) == nil)
    }
}
