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

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let prefill = TransactionPrefill(userInfo: response.notification.request.content.userInfo)
        else { return }
        await MainActor.run { pendingPrefill = prefill }
    }

    // Show automation banners even while the app is foregrounded — without
    // this, iOS silently drops them and in-app users never see failures.
    nonisolated func userNotificationCenter(
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
