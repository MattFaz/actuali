import Foundation
import UserNotifications
import os

private let notifLog = Logger(subsystem: "com.mfazz.Actuali", category: "NewTransactionNotifier")

/// Seam over UNUserNotificationCenter so notify's gating is testable.
protocol NotificationPosting {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

extension UNUserNotificationCenter: NotificationPosting {}

/// Posts one local notification per background-refresh cycle summarizing
/// transactions that arrived via sync (from NewTransactionDetector).
enum NewTransactionNotifier {

    /// Stable so a newer summary replaces the previous one in Notification
    /// Center instead of stacking. Also used as the thread identifier.
    static let requestIdentifier = "com.mfazz.Actuali.newTransactions"

    /// Notification category, used by the tap-through delegate to route to
    /// the transaction editor.
    static let categoryIdentifier = "NEW_TRANSACTIONS"

    /// userInfo key carrying the [String] of new transaction ids.
    static let transactionIdsKey = "transactionIds"

    /// Background refresh calls this unconditionally after every sync; the
    /// user's notification opt-in is enforced here, not at scheduling time,
    /// so the refresh itself can keep data fresh for everyone.
    @MainActor
    static func notify(about transactions: [Transaction], currencyCode: String,
                       accountNames: [String: String] = [:],
                       settings: TransactionNotificationSettings = TransactionNotificationSettings(),
                       center: NotificationPosting = UNUserNotificationCenter.current()) async {
        guard settings.isEnabled else { return }
        guard let request = makeRequest(for: transactions, currencyCode: currencyCode,
                                        accountNames: accountNames) else { return }

        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            notifLog.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard granted else { return }

        do {
            try await center.add(request)
            notifLog.info("Posted new-transaction notification (\(transactions.count) transactions)")
        } catch {
            notifLog.error("Failed to post new-transaction notification: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func makeRequest(for transactions: [Transaction], currencyCode: String,
                            accountNames: [String: String] = [:]) -> UNNotificationRequest? {
        guard let content = makeContent(for: transactions, currencyCode: currencyCode,
                                        accountNames: accountNames) else { return nil }
        return UNNotificationRequest(identifier: requestIdentifier, content: content, trigger: nil)
    }

    /// Detail lines shown for a batch before overflowing into "…and N more".
    /// Long-press/expanded notifications show about this many comfortably.
    static let maxDetailLines = 4

    static func makeContent(for transactions: [Transaction], currencyCode: String,
                            accountNames: [String: String] = [:]) -> UNNotificationContent? {
        guard !transactions.isEmpty else { return nil }

        let content = UNMutableNotificationContent()
        content.threadIdentifier = requestIdentifier
        content.categoryIdentifier = categoryIdentifier
        content.userInfo = [transactionIdsKey: transactions.map(\.id)]
        // No sound — a quiet reminder, matching the Wallet-automation banners.

        content.title = transactions.count == 1
            ? "New transaction"
            : "\(transactions.count) new transactions"

        var lines = transactions.prefix(maxDetailLines).map {
            line(for: $0, currencyCode: currencyCode, accountNames: accountNames)
        }
        if transactions.count > maxDetailLines {
            lines.append("…and \(transactions.count - maxDetailLines) more")
        }
        content.body = lines.joined(separator: "\n")

        return content
    }

    /// One transaction's detail: "$12.50 at Starbucks on Checking", with an
    /// uncategorized marker so each line says whether it still needs sorting.
    private static func line(for transaction: Transaction, currencyCode: String,
                             accountNames: [String: String]) -> String {
        var line = amountString(cents: transaction.amount, currencyCode: currencyCode)
        if let payee = transaction.payeeName, !payee.isEmpty {
            line += " at \(payee)"
        }
        if let account = accountNames[transaction.accountId], !account.isEmpty {
            line += " on \(account)"
        }
        if transaction.categoryId == nil {
            line += " · Needs a category"
        }
        return line
    }

    private static func amountString(cents: Int, currencyCode: String) -> String {
        let dollars = Double(abs(cents)) / 100.0
        return currencyCode.isEmpty
            ? dollars.formatted(.number.precision(.fractionLength(2)))
            : dollars.formatted(.currency(code: currencyCode))
    }
}
