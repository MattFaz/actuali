import Foundation
import os
import UserNotifications

private let notifLog = Logger(subsystem: "com.mfazz.Actuali", category: "CreditCardDueNotifier")

/// Schedules local notifications for credit cards with upcoming payment due dates.
/// Reminders are posted at 7, 5, 3, and 1 days before the due date if the card has
/// an unpaid statement, falling back to the live balance when statement data is unavailable.
@MainActor
final class CreditCardDueNotifier {
    private struct Inputs: Equatable {
        let accounts: [Account]
        let cycles: [String: CreditCardCycle]
        let statementDues: [String: [CreditCardCycle.StatementDue]]
        let currencyCode: String
        let narrowSymbol: Bool
        let enabled: Bool
        let today: DayDate
        let beforeReminderTime: Bool
        let calendar: Calendar
        let locale: String
        var authorizationStatus: UNAuthorizationStatus
    }

    private var lastInputs: Inputs?
    private var authorizationGranted: Bool?

    /// Reminders scheduled at 7, 5, 3, and 1 day before due date.
    nonisolated static let reminderOffsets = [7, 5, 3, 1]

    /// Prefix for all credit card due notifications.
    nonisolated static let identifierPrefix = "com.mfazz.Actuali.creditCardDue."

    /// Notification category for credit card payment reminders.
    nonisolated static let categoryIdentifier = "CREDIT_CARD_DUE"

    /// userInfo key carrying the target accountId.
    nonisolated static let accountIdKey = "accountId"

    nonisolated static func requestIdentifier(accountId: String, offsetDays: Int) -> String {
        "\(identifierPrefix)\(accountId).\(offsetDays)d"
    }

    /// Schedule or cancel notifications based on active credit card cycles,
    /// statement dues, account balances, and the user's notification setting.
    func scheduleNotifications(
        accounts: [Account],
        cycles: [String: CreditCardCycle],
        statementDues: [String: [CreditCardCycle.StatementDue]] = [:],
        currencyCode: String,
        narrowSymbol: Bool = false,
        settings: CreditCardNotificationSettings = CreditCardNotificationSettings(),
        center: any NotificationPosting = UNUserNotificationCenter.current(),
        now: Date = Date(),
        calendar: Calendar = .current
    ) async {
        let authorizationStatus = settings.isEnabled ? await center.authorizationStatus() : .notDetermined
        // A successful prompt and an already-authorized center are the same
        // permission state, so granting the prompt doesn't force a second rebuild.
        let effectiveAuthorization: UNAuthorizationStatus = switch authorizationStatus {
        case .authorized, .provisional, .ephemeral: .authorized
        case .notDetermined where settings.isEnabled && authorizationGranted != nil:
            authorizationGranted == true ? .authorized : .denied
        default: authorizationStatus
        }
        var inputs = Inputs(accounts: accounts, cycles: cycles, statementDues: statementDues,
                            currencyCode: currencyCode, narrowSymbol: narrowSymbol,
                            enabled: settings.isEnabled, today: DayDate.today(calendar: calendar, now: now),
                            beforeReminderTime: calendar.component(.hour, from: now) < 9,
                            calendar: calendar, locale: Locale.current.identifier, authorizationStatus: effectiveAuthorization)
        guard inputs != lastInputs else { return }
        let previous = lastInputs
        lastInputs = inputs
        let accountIds = Set(accounts.map(\.id)).union(cycles.keys)
            .union(previous?.accounts.map(\.id) ?? []).union(previous?.cycles.keys.map(\.self) ?? [])
        guard settings.isEnabled else {
            authorizationGranted = nil
            // Setting is disabled: clear any pending due-date reminders for known accounts.
            let allIds = accountIds.flatMap { accountId in
                Self.reminderOffsets.map { Self.requestIdentifier(accountId: accountId, offsetDays: $0) }
            }
            if !allIds.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: allIds)
            }
            return
        }

        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral: authorizationGranted = true
        case .denied: authorizationGranted = false
        case .notDetermined: break
        @unknown default: authorizationGranted = false
        }
        if authorizationGranted == nil {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard lastInputs == inputs else { return }
                authorizationGranted = granted
                inputs.authorizationStatus = granted ? .authorized : .denied
                lastInputs = inputs
            } catch {
                if lastInputs == inputs {
                    lastInputs = nil
                }
                notifLog.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        guard lastInputs == inputs, authorizationGranted == true else { return }
        var succeeded = true

        let accountsById = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let today = DayDate.today(calendar: calendar, now: now)

        for accountId in accountIds {
            guard lastInputs == inputs else { return }
            let ids = Self.reminderOffsets.map { Self.requestIdentifier(accountId: accountId, offsetDays: $0) }
            let dues = statementDues[accountId]
            let statementDue = dues?.first { today <= $0.dueDate && $0.remainingDue > 0 }
            let isUnpaid = dues == nil
                ? (accountsById[accountId].map { $0.balance < 0 } ?? false)
                : statementDue != nil
            guard let account = accountsById[accountId],
                  !account.closed,
                  isUnpaid,
                  let cycle = cycles[accountId] else {
                center.removePendingNotificationRequests(withIdentifiers: ids)
                continue
            }

            // Card has an unpaid balance. Schedule reminders for upcoming offsets.
            let dueDate = statementDue?.dueDate ?? cycle.upcomingDueDate(for: today)
            for offset in Self.reminderOffsets {
                guard lastInputs == inputs else { return }
                let reminderDay = dueDate.adding(days: -offset)
                var components = DateComponents()
                components.year = reminderDay.year
                components.month = reminderDay.month
                components.day = reminderDay.day
                components.hour = 9
                components.minute = 0

                // Do not schedule notifications for dates/times already in the past.
                let id = Self.requestIdentifier(accountId: accountId, offsetDays: offset)
                guard let scheduledDate = calendar.date(from: components), scheduledDate > now else {
                    center.removePendingNotificationRequests(withIdentifiers: [id])
                    continue
                }

                let content = Self.makeContent(
                    account: account,
                    dueDate: dueDate,
                    offsetDays: offset,
                    statementDue: statementDue,
                    currencyCode: currencyCode,
                    narrowSymbol: narrowSymbol
                )

                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

                do {
                    try await center.add(request)
                } catch {
                    succeeded = false
                    notifLog.error("Failed to schedule notification for \(account.name): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if !succeeded, lastInputs == inputs {
            lastInputs = nil
        }
    }

    nonisolated static func makeContent(
        account: Account,
        dueDate: DayDate,
        offsetDays: Int,
        statementDue: CreditCardCycle.StatementDue? = nil,
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

        let dueDateFormatted = Transaction.formattedDate(from: dueDate.yyyymmdd, style: .abbreviated)
        if let statementDue, statementDue.remainingDue > 0 {
            let dueAmount = CurrencyAmountFormat.string(
                cents: statementDue.remainingDue,
                currencyCode: currencyCode,
                narrowSymbol: narrowSymbol
            )
            content.body = String(format: String(localized: "Statement due %1$@. Payment due %2$@."), dueAmount, dueDateFormatted)
        } else {
            let formattedAmount = CurrencyAmountFormat.string(
                cents: abs(account.balance),
                currencyCode: currencyCode,
                narrowSymbol: narrowSymbol
            )
            content.body = String(format: String(localized: "Current balance %@. Payment due %@."), formattedAmount, dueDateFormatted)
        }

        return content
    }
}
