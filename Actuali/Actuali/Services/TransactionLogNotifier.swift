import Foundation
import UserNotifications
import os

private let notifLog = Logger(subsystem: "com.mfazz.Actuali", category: "TransactionLogNotifier")

/// Marker payload carried on a success notification. Tapping a notification
/// with this marker navigates to the All Accounts transaction list.
enum TransactionLoggedMarker {
    static let kind = "com.mfazz.Actuali.transactionLogged"

    static var userInfo: [AnyHashable: Any] { ["kind": kind] }

    static func isPresent(in userInfo: [AnyHashable: Any]) -> Bool {
        userInfo["kind"] as? String == kind
    }
}

@MainActor
enum TransactionLogNotifier {

    /// - Parameter synced: false when the row is written locally but hasn't
    ///   reached the server yet, which the banner says outright — otherwise the
    ///   transaction looks logged while the budget on the server is unchanged.
    static func notifySuccess(payee: String, amountCents: Int, currencyCode: String,
                              narrowSymbol: Bool = false, synced: Bool = true) async {
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
        content.title = synced ? String(localized: "Logged transaction") : String(localized: "Saved locally")
        content.body = composeSuccessBody(payee: payee, amountCents: amountCents,
                                          currencyCode: currencyCode, narrowSymbol: narrowSymbol,
                                          synced: synced)
        // No sound — quiet success banner that auto-dismisses.
        content.userInfo = TransactionLoggedMarker.userInfo

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

    static func notifyFailure(message: String, payee: String?, amountCents: Int?,
                              currencyCode: String, narrowSymbol: Bool = false,
                              prefill: TransactionPrefill? = nil) async {
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
        content.title = String(localized: "Couldn't log transaction")
        content.body = composeBody(message: message, payee: payee, amountCents: amountCents,
                                   currencyCode: currencyCode, narrowSymbol: narrowSymbol)
        content.sound = .default
        if let prefill {
            content.body += " " + String(localized: "Tap to add it manually.")
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

    static func composeBody(message: String, payee: String?, amountCents: Int?,
                            currencyCode: String, narrowSymbol: Bool = false,
                            locale: Locale = .autoupdatingCurrent) -> String {
        var parts: [String] = []
        if let amountCents {
            let amountString = CurrencyAmountFormat.string(cents: amountCents,
                                                           currencyCode: currencyCode,
                                                           narrowSymbol: narrowSymbol,
                                                           locale: locale)
            parts.append(amountString)
        }
        if let payee, !payee.isEmpty {
            parts.append(String(format: String(localized: "at %@", locale: locale), payee))
        }
        let prefix = parts.joined(separator: " ")
        return prefix.isEmpty ? message : "\(prefix). \(message)"
    }

    static func composeSuccessBody(payee: String, amountCents: Int, currencyCode: String,
                                   narrowSymbol: Bool, synced: Bool = true,
                                   locale: Locale = .autoupdatingCurrent) -> String {
        let amountString = CurrencyAmountFormat.string(cents: amountCents,
                                                       currencyCode: currencyCode,
                                                       narrowSymbol: narrowSymbol,
                                                       locale: locale)
        let prefix = payee.isEmpty
            ? amountString
            : String(format: String(localized: "%@ at %@", locale: locale), amountString, payee)
        guard synced else {
            return "\(prefix). " + String(localized: "Couldn't reach your server — it will sync when you open Actuali.", locale: locale)
        }
        return prefix
    }
}
