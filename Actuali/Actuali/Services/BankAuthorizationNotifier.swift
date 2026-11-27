import Foundation
import UserNotifications

/// Calls the person back once their bank has answered an Enable Banking
/// authorization. The approval often ends in the banking app or the browser,
/// on a page that isn't this app's and can't reopen it, so a banner is the one
/// thing that reaches them there. Tapping it just opens the app, which is still
/// on the screen that shows the outcome.
enum BankAuthorizationNotifier {
    /// Stable, so the screen can clear the banner once the person is back.
    static let requestIdentifier = "com.mfazz.Actuali.bankAuthorization"

    /// Posts only where notifications are already allowed: asking in the
    /// middle of a bank authorization would stack a second system prompt on
    /// the browser's own.
    @MainActor
    static func notifyApproved(center: any NotificationPosting = UNUserNotificationCenter.current()) async {
        guard await center.authorizationStatus() == .authorized else { return }
        try? await center.add(makeRequest())
    }

    static func makeRequest() -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Your bank approved access")
        content.body = String(localized: "Come back to Actuali to continue.")
        content.sound = .default
        return UNNotificationRequest(identifier: requestIdentifier, content: content, trigger: nil)
    }
}
