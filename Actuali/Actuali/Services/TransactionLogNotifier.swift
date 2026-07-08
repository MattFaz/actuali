import Foundation
import UserNotifications
import os

private let notifLog = Logger(subsystem: "com.mfazz.Actuali", category: "TransactionLogNotifier")

@MainActor
enum TransactionLogNotifier {

    static func notifySuccess(payee: String, amountCents: Int, currencyCode: String) async {
        let center = UNUserNotificationCenter.current()

        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            notifLog.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = "Logged transaction"
        content.body = composeSuccessBody(payee: payee, amountCents: amountCents, currencyCode: currencyCode)
        // No sound — quiet success banner that auto-dismisses.

        let request = UNNotificationRequest(
            identifier: "com.mfazz.Actuali.logTransactionSuccess.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
        } catch {
            notifLog.error("Failed to post success notification: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func notifyFailure(message: String, payee: String?, amountCents: Int?, prefill: TransactionPrefill? = nil) async {
        let center = UNUserNotificationCenter.current()

        // Request permission lazily on first call. Quietly ignore denial — without
        // permission we can't notify, but we still want the AppIntent to throw a
        // banner-visible error so the user isn't left in the dark.
        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            notifLog.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = "Couldn't log transaction"
        content.body = composeBody(message: message, payee: payee, amountCents: amountCents)
        content.sound = .default
        if let prefill {
            content.body += " Tap to add it manually."
            content.userInfo = prefill.userInfo
        }

        let request = UNNotificationRequest(
            identifier: "com.mfazz.Actuali.logTransactionFailure.\(UUID().uuidString)",
            content: content,
            trigger: nil   // deliver immediately
        )

        do {
            try await center.add(request)
        } catch {
            notifLog.error("Failed to post failure notification: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func composeBody(message: String, payee: String?, amountCents: Int?) -> String {
        var parts: [String] = []
        if let amountCents {
            let dollars = Double(abs(amountCents)) / 100.0
            parts.append(String(format: "$%.2f", dollars))
        }
        if let payee, !payee.isEmpty {
            parts.append("at \(payee)")
        }
        let prefix = parts.joined(separator: " ")
        return prefix.isEmpty ? message : "\(prefix). \(message)"
    }

    private static func composeSuccessBody(payee: String, amountCents: Int, currencyCode: String) -> String {
        let dollars = Double(abs(amountCents)) / 100.0
        let amountString = currencyCode.isEmpty
            ? dollars.formatted(.number.precision(.fractionLength(2)))
            : dollars.formatted(.currency(code: currencyCode))
        return payee.isEmpty ? amountString : "\(amountString) at \(payee)"
    }
}
