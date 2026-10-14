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

/// Hosts `AppLockView` in its own window above the app's, because an overlay
/// on the root view would leave any open sheet or alert uncovered.
@MainActor
enum AppLockWindow {
    private static var window: UIWindow?

    static func update(locked: Bool, store: BudgetStore) {
        if !locked {
            window?.isHidden = true
            window = nil
            return
        }
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }
        // Dismiss the keyboard: its window sits above any level we can pick.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: AppLockView().environmentObject(store))
        window.isHidden = false
        self.window = window
    }
}
