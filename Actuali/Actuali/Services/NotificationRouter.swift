import Combine
import Foundation
import UIKit
import UserNotifications

/// Publishes the prefill from a tapped log-failure notification so the UI can
/// open the add-transaction form. Set as the notification-center delegate at
/// launch (via `AppDelegate`) so taps that cold-start the app are delivered.
@MainActor
final class NotificationRouter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    @Published var pendingPrefill: TransactionPrefill?

    // These async delegate methods must stay MainActor-isolated: the bridged
    // completion handler runs on whatever executor the method finishes on,
    // and UIKit's post-response work (state restoration, snapshotting)
    // asserts it is on the main thread. Marking them nonisolated crashes the
    // app on every notification tap.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let prefill = TransactionPrefill(userInfo: response.notification.request.content.userInfo)
        else { return }
        pendingPrefill = prefill
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
