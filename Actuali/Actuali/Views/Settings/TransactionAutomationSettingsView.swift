import SwiftUI
import UIKit
import UserNotifications

struct TransactionAutomationSettingsView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @State private var transactionNotificationsEnabled = TransactionNotificationSettings().isEnabled
    @State private var notificationPermissionDenied = false
    @State private var showingWalletImport = false

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

    var body: some View {
        Form {
            Section {
                // Default Account remains reachable for loaded demo and
                // offline budgets. Shortcuts and Wallet automation can't post
                // without it (GH #122).
                if budgetStore.currentBudgetId != nil {
                    Picker(String(localized: "Default Account"), selection: $budgetStore.defaultAccountId) {
                        Text(String(localized: "None")).tag(nil as String?)
                        ForEach(budgetStore.accounts.filter { !$0.closed }) { account in
                            Text(account.name).tag(account.id as String?)
                        }
                    }
                } else {
                    Text(String(localized: "Load a budget to choose a default account."))
                        .foregroundStyle(.secondary)
                }

                Toggle(String(localized: "Conventional Amount Entry"), isOn: $budgetStore.conventionalAmountEntry)
            } header: {
                Text(String(localized: "Defaults"))
            } footer: {
                Text(String(localized: "New transactions, Siri Shortcuts, and Wallet automation use the Default Account when no account is chosen. Conventional Amount Entry types 324 as 324.00 instead of filling cents first."))
            }

            Section(String(localized: "Transaction Behavior")) {
                Picker(String(localized: "View Transactions As"), selection: $budgetStore.transactionDisplayMode) {
                    ForEach(TransactionDisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                Picker(String(localized: "Uncategorized Action"), selection: $budgetStore.uncategorizedTapAction) {
                    ForEach(UncategorizedTapAction.allCases) { action in
                        Text(action.label).tag(action)
                    }
                }
            }

            Section {
                // Meaningless against servers that predate payee
                // locations (< 26.4.0), so hidden there.
                if budgetStore.payeeLocationWritesEnabled {
                    Toggle(String(localized: "Record Payee Locations"), isOn: $budgetStore.recordPayeeLocations)

                    // Clearing needs the same >= 26.4.0 server, so this
                    // lives inside the gate too (GH #147).
                    NavigationLink(String(localized: "Payee Locations")) {
                        PayeeLocationsView()
                    }
                }

                if budgetStore.currentBudgetId != nil {
                    NavigationLink {
                        CardAccountMappingsView()
                    } label: {
                        HStack {
                            Text(String(localized: "Card & Account Mappings"))
                            Spacer()
                            if !budgetStore.cardAccountMappings.isEmpty {
                                Text("\(budgetStore.cardAccountMappings.count)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    NavigationLink {
                        CreditCardsSettingsView()
                    } label: {
                        HStack {
                            Text(String(localized: "Credit Cards & Billing Cycles"))
                            Spacer()
                            // Same predicate the screen itself lists, so the
                            // badge can't promise cards the list won't show.
                            let cardCount = budgetStore.activeCreditCardStatementDays.count
                            if cardCount > 0 {
                                Text("\(cardCount)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !budgetStore.payeeLocationWritesEnabled
                    && budgetStore.currentBudgetId == nil {
                    Text(String(localized: "Load a budget to manage transaction accounts."))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(String(localized: "Payees & Accounts"))
            } footer: {
                if !budgetStore.payeeLocationWritesEnabled
                    && budgetStore.currentBudgetId != nil
                    && budgetStore.isConnected {
                    Text(String(localized: "Payee locations require Actual Server 26.4.0 or later."))
                }
            }

            Section {
                Toggle(String(localized: "New Transaction Alerts"), isOn: transactionNotificationsBinding)

                if notificationPermissionDenied {
                    Button(String(localized: "Open Settings to Allow Notifications")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            } header: {
                Text(String(localized: "Notifications"))
            } footer: {
                if notificationPermissionDenied {
                    Text(String(localized: "Notifications are turned off for Actuali in the Settings app, so transaction alerts can't be delivered."))
                } else {
                    Text(String(localized: "Get notified when transactions from bank sync or other devices arrive, so you can categorize them. iOS checks a few times a day and requires Background App Refresh."))
                }
            }

            Section {
                if budgetStore.currentBudgetId != nil {
                    NavigationLink {
                        CategoryFundingAutomationView()
                    } label: {
                        Label(String(localized: "Category Funding Settings"), systemImage: "arrow.up.circle")
                    }
                } else {
                    Text(String(localized: "Load a budget to configure Category Funding."))
                        .foregroundStyle(.secondary)
                }

                NavigationLink {
                    WalletAutomationView()
                } label: {
                    Label(String(localized: "Log Wallet Payments Automatically"), systemImage: "wallet.pass")
                }

                if WalletImportView.isSupported {
                    Button {
                        showingWalletImport = true
                    } label: {
                        Label(String(localized: "Import Wallet Transactions"), systemImage: "square.and.arrow.down")
                    }
                }
            } header: {
                Text(String(localized: "Automations"))
            } footer: {
                if WalletImportView.isSupported {
                    Text(String(localized: "Category Funding runs only for manual expenses entered from the selected account and funds only the required shortfall. Set up a Shortcuts automation that logs tap-to-pay purchases from Apple Wallet, or import Apple Card, Apple Cash and Savings transactions directly."))
                } else {
                    Text(String(localized: "Category Funding runs only for manual expenses entered from the selected account and funds only the required shortfall. Set up a Shortcuts automation that logs tap-to-pay purchases from Apple Wallet."))
                }
            }
        }
        .readableWidth()
        .navigationTitle(String(localized: "Transactions & Automation"))
        .navigationBarTitleDisplayMode(.inline)
        .contentMargins(.horizontal, 6, for: .scrollContent)
        .task { await refreshNotificationPermissionState() }
        .sheet(isPresented: $showingWalletImport) {
            WalletImportView()
                .environmentObject(budgetStore)
        }
    }

    private func enableTransactionNotifications() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        notificationPermissionDenied = !granted
    }

    /// Permission can change in the Settings app while we're backgrounded;
    /// re-check whenever the screen appears.
    private func refreshNotificationPermissionState() async {
        guard transactionNotificationsEnabled else { return }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationPermissionDenied = status == .denied
    }
}
