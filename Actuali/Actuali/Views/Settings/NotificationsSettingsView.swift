import SwiftUI
import UIKit
import UserNotifications

struct NotificationsSettingsView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @State private var transactionNotificationsEnabled = TransactionNotificationSettings().isEnabled
    @State private var creditCardDueNotificationsEnabled = CreditCardNotificationSettings().isEnabled
    @State private var notificationPermissionDenied = false

    /// Persists the opt-in and requests permission on enable. Background
    /// refresh runs regardless of this toggle (it keeps data fresh for
    /// everyone); only notification posting is gated on it.
    private var transactionNotificationsBinding: Binding<Bool> {
        Binding(
            get: { transactionNotificationsEnabled },
            set: { enabled in
                transactionNotificationsEnabled = enabled
                TransactionNotificationSettings().isEnabled = enabled
                if enabled {
                    Task { await enableTransactionNotifications() }
                } else {
                    notificationPermissionDenied = false
                }
            }
        )
    }

    private var creditCardDueRemindersBinding: Binding<Bool> {
        Binding(
            get: { creditCardDueNotificationsEnabled },
            set: { enabled in
                creditCardDueNotificationsEnabled = enabled
                CreditCardNotificationSettings().isEnabled = enabled
                Task {
                    if enabled {
                        await enableTransactionNotifications()
                    }
                    await budgetStore.scheduleCreditCardDueNotifications()
                }
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "New Transaction Alerts"), isOn: transactionNotificationsBinding)
                    .accessibilityIdentifier("notifications.newTransactionAlerts")
                Toggle(String(localized: "Credit Card Due Reminders"), isOn: creditCardDueRemindersBinding)
                    .accessibilityIdentifier("notifications.creditCardDueReminders")

                if notificationPermissionDenied {
                    Button(String(localized: "Open Settings to Allow Notifications")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .accessibilityIdentifier("notifications.openSettings")
                }
            } footer: {
                if notificationPermissionDenied {
                    Text(String(localized: "Notifications are turned off for Actuali in the Settings app, so alerts can't be delivered."))
                } else {
                    Text(String(localized: "New transaction alerts require Background App Refresh. Credit card due reminders are sent 7, 5, 3, and 1 days before payment is due for cards with an unpaid balance."))
                }
            }
        }
        .readableWidth()
        .navigationTitle(String(localized: "Notifications"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshNotificationPermissionState() }
    }

    private func enableTransactionNotifications() async {
        let center = UNUserNotificationCenter.current()
        let granted = await (try? center.requestAuthorization(options: [.alert, .sound])) ?? false
        notificationPermissionDenied = !granted
    }

    /// Permission can change in the Settings app while we're backgrounded;
    /// re-check whenever the screen appears.
    private func refreshNotificationPermissionState() async {
        guard transactionNotificationsEnabled || creditCardDueNotificationsEnabled else { return }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationPermissionDenied = status == .denied
    }
}
