import UIKit

/// Defines Home Screen quick actions and routes them into scene navigation.
enum ActualiHomeScreenShortcut {
    static let addTransactionType = "com.mfazz.Actuali.addTransaction"

    @MainActor
    static var addTransaction: UIApplicationShortcutItem {
        UIApplicationShortcutItem(
            type: addTransactionType,
            localizedTitle: StartTab.addTransaction.label(locale: .current),
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
              let tab = Self.tab(for: shortcutItem) else {
            return
        }
        NotificationRouter.shared.pendingTabNavigation = tab
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem
    ) async -> Bool {
        guard let tab = Self.tab(for: shortcutItem) else {
            return false
        }
        NotificationRouter.shared.pendingTabNavigation = tab
        return true
    }

    nonisolated static func tab(for shortcutItem: UIApplicationShortcutItem) -> Int? {
        shortcutItem.type == ActualiHomeScreenShortcut.addTransactionType
            ? StartTab.addTransaction.tabTag
            : nil
    }
}
