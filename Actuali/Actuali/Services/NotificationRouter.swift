import Combine
import Foundation
import UIKit
import UserNotifications

/// Screen a tapped new-transaction notification resolves to. Identifiable so
/// ContentView can drive a sheet from it.
enum NotificationDestination: Identifiable, Equatable {
    case editor(Transaction)
    case uncategorized

    var id: String {
        switch self {
        case .editor(let transaction): return "editor-\(transaction.id)"
        case .uncategorized: return "uncategorized"
        }
    }
}

/// Routes tapped notifications to pending UI state. New-transaction
/// notifications resolve to a destination (a single transaction opens its
/// editor, a batch — or a transaction that no longer exists — opens the
/// uncategorized list). A log-failure tap opens the add-transaction form with
/// its prefill; a log-success tap navigates to the All Accounts transaction
/// list. Set as the notification-center delegate at launch (via `AppDelegate`)
/// so taps that cold-start the app are delivered.
@MainActor
final class NotificationRouter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationRouter()

    /// From a tapped log-failure notification (Wallet automation).
    @Published var pendingPrefill: TransactionPrefill?
    @Published var pendingAllAccountsNavigation = false

    /// From a tapped new-transaction notification.
    @Published var destination: NotificationDestination?

    enum Route: Equatable {
        case editTransaction(id: String)
        case uncategorized
    }

    /// Pure mapping from a tapped notification's payload to a route.
    /// Returns nil for notifications this route doesn't own (e.g. the
    /// Wallet-automation banners, which carry a prefill or logged-marker).
    nonisolated static func route(categoryIdentifier: String,
                                  userInfo: [AnyHashable: Any]) -> Route? {
        guard categoryIdentifier == NewTransactionNotifier.categoryIdentifier else { return nil }
        let ids = userInfo[NewTransactionNotifier.transactionIdsKey] as? [String] ?? []
        if ids.count == 1, let id = ids.first {
            return .editTransaction(id: id)
        }
        return .uncategorized
    }

    /// Resolve a route against the store. Waits for the budget to load (a
    /// cold-launch tap arrives before `loadLocalBudget` finishes) and degrades
    /// to the uncategorized list when the transaction has since disappeared.
    static func destination(for route: Route, in store: BudgetStore) async -> NotificationDestination {
        switch route {
        case .uncategorized:
            return .uncategorized
        case .editTransaction(let id):
            await store.ensureBudgetReady()
            if let transaction = await store.transaction(withId: id) {
                return .editor(transaction)
            }
            return .uncategorized
        }
    }

    // These async delegate methods must stay MainActor-isolated: the bridged
    // completion handler runs on whatever executor the method finishes on,
    // and UIKit's post-response work (state restoration, snapshotting)
    // asserts it is on the main thread. Marking them nonisolated crashes the
    // app on every notification tap.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        if let newTransactionRoute = Self.route(categoryIdentifier: content.categoryIdentifier,
                                                userInfo: content.userInfo) {
            destination = await Self.destination(for: newTransactionRoute, in: BudgetStore.shared)
            return
        }
        route(userInfo: content.userInfo)
    }

    /// Maps a tapped log notification's payload to pending UI state. Internal
    /// so unit tests can drive it without a real UNNotificationResponse.
    func route(userInfo: [AnyHashable: Any]) {
        if let prefill = TransactionPrefill(userInfo: userInfo) {
            pendingPrefill = prefill
        } else if TransactionLoggedMarker.isPresent(in: userInfo) {
            pendingAllAccountsNavigation = true
        }
    }

    // Show banners even while the app is foregrounded — without this, iOS
    // silently drops them and in-app users never see them. Union of both
    // notification kinds' needs: the automation banners carry sound,
    // new-transaction summaries are silent and should also land in
    // Notification Center's list.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        return true
    }
}
