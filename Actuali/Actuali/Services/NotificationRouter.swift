import Combine
import Foundation
import UIKit
import UserNotifications

/// Routes tapped notifications to pending UI state: a log-failure tap opens
/// the add-transaction form with its prefill; a log-success tap navigates to
/// the All Accounts transaction list. Set as the notification-center delegate
/// at launch (via `AppDelegate`) so taps that cold-start the app are delivered.
@MainActor
final class NotificationRouter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    @Published var pendingPrefill: TransactionPrefill?
    @Published var pendingAllAccountsNavigation = false

    // These async delegate methods must stay MainActor-isolated: the bridged
    // completion handler runs on whatever executor the method finishes on,
    // and UIKit's post-response work (state restoration, snapshotting)
    // asserts it is on the main thread. Marking them nonisolated crashes the
    // app on every notification tap.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        route(userInfo: response.notification.request.content.userInfo)
    }

    /// Maps a tapped notification's payload to pending UI state. Internal so
    /// unit tests can drive it without a real UNNotificationResponse.
    func route(userInfo: [AnyHashable: Any]) {
        if let prefill = TransactionPrefill(userInfo: userInfo) {
            pendingPrefill = prefill
        } else if TransactionLoggedMarker.isPresent(in: userInfo) {
            pendingAllAccountsNavigation = true
        }
    }

    // Show automation banners even while the app is foregrounded — without
    // this, iOS silently drops them and in-app users never see failures.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
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
