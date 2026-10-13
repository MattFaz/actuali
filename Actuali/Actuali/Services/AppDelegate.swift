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
              let (scrollView, rect) = Self.caretScrollTarget(for: textView) else { return }
        scrollView.scrollRectToVisible(rect, animated: true)
    }

    /// The scroll view enclosing `textView`, and the rect in it to keep visible.
    static func caretScrollTarget(for textView: UITextView) -> (UIScrollView, CGRect)? {
        guard let end = textView.selectedTextRange?.end,
              let scrollView = sequence(first: textView.superview, next: { $0?.superview })
              .lazy.compactMap({ $0 as? UIScrollView }).first
        else { return nil }
        // A field at its line limit scrolls inside itself, and may not have
        // caught up with the caret yet, so never aim the form past the field.
        let caret = textView.caretRect(for: end)
        let target = caret.intersects(textView.bounds) ? caret : textView.bounds
        return (scrollView, textView.convert(target, to: scrollView).insetBy(dx: 0, dy: -12))
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
