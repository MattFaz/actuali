import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        UIApplication.shared.shortcutItems = [ActualiHomeScreenShortcut.addTransaction]
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollCaretToVisible(_:)),
            name: UITextView.textDidChangeNotification,
            object: nil
        )
        return true
    }

    /// SwiftUI scrolls a form to a text field only as the field gains focus.
    /// A multi-line field (`TextField(axis: .vertical)`, `TextEditor`) that
    /// then grows while typing runs under the keyboard (GH #674), so after
    /// each edit scroll the caret, plus a little air, back into view. The
    /// scroll view's insets already exclude the keyboard.
    @objc private func scrollCaretToVisible(_ notification: Notification) {
        guard let textView = notification.object as? UITextView,
              let caret = textView.selectedTextRange?.end else { return }
        var ancestor = textView.superview
        while let view = ancestor, !(view is UIScrollView) {
            ancestor = view.superview
        }
        guard let scrollView = ancestor as? UIScrollView else { return }
        let rect = textView.convert(textView.caretRect(for: caret), to: scrollView)
        scrollView.scrollRectToVisible(rect.insetBy(dx: 0, dy: -12), animated: true)
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        if connectingSceneSession.role == .windowApplication {
            configuration.delegateClass = ActualiSceneDelegate.self
        }
        return configuration
    }
}
