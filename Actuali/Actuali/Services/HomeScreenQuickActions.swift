import UIKit

/// Defines Home Screen quick actions and routes them into scene navigation.
enum ActualiHomeScreenShortcut {
    static let addTransactionType = "com.mfazz.Actuali.addTransaction"

    @MainActor
    static var addTransaction: UIApplicationShortcutItem {
        UIApplicationShortcutItem(
            type: addTransactionType,
            localizedTitle: String(localized: "Add Transaction"),
            localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(systemImageName: "plus")
        )
    }
}

@MainActor
final class ActualiSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let shortcutItem = connectionOptions.shortcutItem,
              Self.isAddTransaction(shortcutItem) else {
            return
        }
        NotificationRouter.shared.pendingAddTransaction = true
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem
    ) async -> Bool {
        guard Self.isAddTransaction(shortcutItem) else {
            return false
        }
        NotificationRouter.shared.pendingAddTransaction = true
        return true
    }

    nonisolated static func isAddTransaction(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        shortcutItem.type == ActualiHomeScreenShortcut.addTransactionType
    }
}
