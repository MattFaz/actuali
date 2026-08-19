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

/// Posts one local notification per sync cycle summarizing transactions that
/// arrived from other devices (from NewTransactionDetector). Foreground and
/// background syncs both post it; NotificationRouter's willPresent shows the
/// banner even while the app is open.
enum NewTransactionNotifier {

    /// Stable so a newer summary replaces the previous one in Notification
    /// Center instead of stacking. Also used as the thread identifier.
    static let requestIdentifier = "com.mfazz.Actuali.newTransactions"

    /// Notification category, used by the tap-through delegate to route to
    /// the transaction editor.
    static let categoryIdentifier = "NEW_TRANSACTIONS"

    /// userInfo key carrying the [String] of new transaction ids.
    static let transactionIdsKey = "transactionIds"

    /// Every sync path calls this unconditionally; the user's notification
    /// opt-in is enforced here, not at scheduling time, so syncing itself
    /// keeps data fresh for everyone.
    @MainActor
    static func notify(about transactions: [Transaction], currencyCode: String,
                       narrowSymbol: Bool = false,
                       accountNames: [String: String] = [:],
                       offBudgetAccountIds: Set<String> = [],
                       settings: TransactionNotificationSettings = TransactionNotificationSettings(),
                       center: NotificationPosting = UNUserNotificationCenter.current()) async {
        guard settings.isEnabled else { return }
        guard let request = makeRequest(for: transactions, currencyCode: currencyCode,
                                        narrowSymbol: narrowSymbol,
                                        accountNames: accountNames,
                                        offBudgetAccountIds: offBudgetAccountIds) else { return }

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
                            narrowSymbol: Bool = false,
                            accountNames: [String: String] = [:],
                            offBudgetAccountIds: Set<String> = []) -> UNNotificationRequest? {
        guard let content = makeContent(for: transactions, currencyCode: currencyCode,
                                        narrowSymbol: narrowSymbol,
                                        accountNames: accountNames,
                                        offBudgetAccountIds: offBudgetAccountIds) else { return nil }
        return UNNotificationRequest(identifier: requestIdentifier, content: content, trigger: nil)
    }

    /// Detail lines shown for a batch before overflowing into "…and N more".
    /// Long-press/expanded notifications show about this many comfortably.
    static let maxDetailLines = 4

    static func makeContent(for transactions: [Transaction], currencyCode: String,
                            narrowSymbol: Bool = false,
                            accountNames: [String: String] = [:],
                            offBudgetAccountIds: Set<String> = []) -> UNNotificationContent? {
        guard !transactions.isEmpty else { return nil }

        let content = UNMutableNotificationContent()
        content.threadIdentifier = requestIdentifier
        content.categoryIdentifier = categoryIdentifier
        content.userInfo = [transactionIdsKey: transactions.map(\.id)]
        // No sound — a quiet reminder, matching the Wallet-automation banners.

        // Interpolation, not a count ternary: the catalog's plural variations
        // pick the right CLDR category per locale (fr/pt-BR treat 0 as "one").
        content.title = String(localized: "\(transactions.count) new transactions")

        var lines = transactions.prefix(maxDetailLines).map {
            line(for: $0, currencyCode: currencyCode, narrowSymbol: narrowSymbol,
                 accountNames: accountNames, offBudgetAccountIds: offBudgetAccountIds)
        }
        if transactions.count > maxDetailLines {
            lines.append(
                String(
                    format: String(localized: "…and %lld more"),
                    Int64(transactions.count - maxDetailLines)
                )
            )
        }
        content.body = lines.joined(separator: "\n")

        return content
    }

    /// One transaction's detail: "$12.50 at Starbucks on Checking", with an
    /// uncategorized marker so each line says whether it still needs sorting.
    /// Transfers and off-budget transactions never take a category, so they
    /// carry no marker (GH #104, #123).
    private static func line(for transaction: Transaction, currencyCode: String,
                             narrowSymbol: Bool,
                             accountNames: [String: String],
                             offBudgetAccountIds: Set<String>) -> String {
        var line = CurrencyAmountFormat.string(cents: transaction.amount,
                                               currencyCode: currencyCode,
                                               narrowSymbol: narrowSymbol)
        if let payee = transaction.payeeName, !payee.isEmpty {
            line = String(format: String(localized: "%@ at %@"), line, payee)
        }
        if let account = accountNames[transaction.accountId], !account.isEmpty {
            line = String(format: String(localized: "%@ on %@"), line, account)
        }
        if transaction.needsCategory(offBudgetAccountIds: offBudgetAccountIds) {
            line += " · " + String(localized: "Needs a category")
        }
        return line
    }
}
