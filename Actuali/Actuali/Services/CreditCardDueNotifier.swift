import Foundation
import UserNotifications
import os

private let notifLog = Logger(subsystem: "com.mfazz.Actuali", category: "CreditCardDueNotifier")

/// Schedules local notifications for credit cards with upcoming payment due dates.
/// Reminders are posted at 7, 5, 3, and 1 days before the due date if the card has
/// an unpaid balance (`balance < 0`).
enum CreditCardDueNotifier {
    /// Reminders scheduled at 7, 5, 3, and 1 day before due date.
    static let reminderOffsets = [7, 5, 3, 1]

    /// Prefix for all credit card due notifications.
    static let identifierPrefix = "com.mfazz.Actuali.creditCardDue."

    /// Notification category for credit card payment reminders.
    static let categoryIdentifier = "CREDIT_CARD_DUE"

    /// userInfo key carrying the target accountId.
    static let accountIdKey = "accountId"

    nonisolated static func requestIdentifier(accountId: String, offsetDays: Int) -> String {
        "\(identifierPrefix)\(accountId).\(offsetDays)d"
    }

    /// Schedule or cancel notifications based on active credit card cycles,
    /// account balances, and the user's notification setting.
    nonisolated static func scheduleNotifications(
        accounts: [Account],
        cycles: [String: CreditCardCycle],
        currencyCode: String,
        narrowSymbol: Bool = false,
        settings: CreditCardNotificationSettings = CreditCardNotificationSettings(),
        center: any NotificationPosting = UNUserNotificationCenter.current(),
        now: Date = Date(),
        calendar: Calendar = .current
    ) async {
        guard settings.isEnabled else {
            // Setting is disabled: clear any pending due-date reminders for known accounts.
            let allIds = Set(accounts.map(\.id)).union(cycles.keys).flatMap { accountId in
                reminderOffsets.map { requestIdentifier(accountId: accountId, offsetDays: $0) }
            }
            if !allIds.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: allIds)
            }
            return
        }

        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            notifLog.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard granted else { return }

        let accountsById = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let today = DayDate.today(calendar: calendar, now: now)

        for accountId in Set(accounts.map(\.id)).union(cycles.keys) {
            let ids = reminderOffsets.map { requestIdentifier(accountId: accountId, offsetDays: $0) }
            guard let account = accountsById[accountId],
                  !account.closed,
                  account.balance < 0,
                  let cycle = cycles[accountId] else {
                center.removePendingNotificationRequests(withIdentifiers: ids)
                continue
            }

            // Card has an unpaid balance (< 0). Schedule reminders for upcoming offsets.
            let dueDate = cycle.upcomingDueDate(for: today)
            for offset in reminderOffsets {
                let reminderDay = dueDate.adding(days: -offset)
                var components = DateComponents()
                components.year = reminderDay.year
                components.month = reminderDay.month
                components.day = reminderDay.day
                components.hour = 9
                components.minute = 0

                // Do not schedule notifications for dates/times already in the past.
                let id = requestIdentifier(accountId: accountId, offsetDays: offset)
                guard let scheduledDate = calendar.date(from: components), scheduledDate > now else {
                    center.removePendingNotificationRequests(withIdentifiers: [id])
                    continue
                }

                let content = makeContent(
                    account: account,
                    dueDate: dueDate,
                    offsetDays: offset,
                    currencyCode: currencyCode,
                    narrowSymbol: narrowSymbol
                )

                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

                do {
                    try await center.add(request)
                } catch {
                    notifLog.error("Failed to schedule notification for \(account.name): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    nonisolated static func makeContent(
        account: Account,
        dueDate: DayDate,
        offsetDays: Int,
        currencyCode: String,
        narrowSymbol: Bool
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = categoryIdentifier
        content.userInfo = [accountIdKey: account.id]
        content.sound = .default

        let daysText = offsetDays == 1
            ? String(localized: "tomorrow")
            : String(format: String(localized: "in %lld days"), Int64(offsetDays))
        content.title = String(format: String(localized: "%@ payment due %@"), account.name, daysText)

        let formattedAmount = CurrencyAmountFormat.string(
            cents: abs(account.balance),
            currencyCode: currencyCode,
            narrowSymbol: narrowSymbol
        )
        let dueDateFormatted = Transaction.formattedDate(from: dueDate.yyyymmdd, style: .abbreviated)
        content.body = String(format: String(localized: "Current balance %@. Payment due %@."), formattedAmount, dueDateFormatted)

        return content
    }
}
