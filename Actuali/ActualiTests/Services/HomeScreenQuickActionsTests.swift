import Testing
import UIKit
@testable import Actuali

@MainActor
struct HomeScreenQuickActionsTests {
    @Test func addTransactionShortcutSelectsAddTab() {
        let shortcut = ActualiHomeScreenShortcut.addTransaction
        #expect(ActualiSceneDelegate.tab(for: shortcut) == StartTab.addTransaction.tabTag)
        #expect(shortcut.localizedTitle == StartTab.addTransaction.label(locale: .current))
    }

    @Test func unrelatedShortcutIsIgnored() {
        let shortcut = UIApplicationShortcutItem(
            type: "com.mfazz.Actuali.otherShortcut",
            localizedTitle: "Other"
        )
        #expect(ActualiSceneDelegate.tab(for: shortcut) == nil)
    }
}
