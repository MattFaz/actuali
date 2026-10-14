import SwiftUI
import UIKit

/// Covers the app while `BudgetStore.isAppLocked` (GH #717).
struct AppLockView: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(String(localized: "Actuali is Locked"))
                .font(.title2.bold())
            Button(String(localized: "Unlock")) {
                Task { await budgetStore.unlockApp() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("appLock.unlock")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .preferredColorScheme(budgetStore.appearanceMode.colorScheme)
    }
}

/// Hosts `AppLockView` in its own window above each of the app's, because an
/// overlay on the root view would leave any open sheet or alert uncovered.
/// One per scene: on iPad a second app window would otherwise stay usable.
@MainActor
enum AppLockWindow {
    /// The lock window and the window that was key before it, by scene session.
    private static var windows: [String: (lock: UIWindow, previousKey: UIWindow?)] = [:]

    static func update(locked: Bool, store: BudgetStore) {
        guard locked else {
            for (lock, previousKey) in windows.values {
                lock.isHidden = true
                previousKey?.makeKey()
            }
            windows.removeAll()
            return
        }
        // Dismiss the keyboard: its window sits above any level we can pick.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            where windows[scene.session.persistentIdentifier] == nil {
            let previousKey = scene.keyWindow
            let host = UIHostingController(rootView: AppLockView().environmentObject(store))
            // Keeps VoiceOver from reading balances in the windows below.
            host.view.accessibilityViewIsModal = true
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            window.rootViewController = host
            window.makeKeyAndVisible()
            windows[scene.session.persistentIdentifier] = (window, previousKey)
        }
    }
}
