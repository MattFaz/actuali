import SwiftUI
import UIKit
import UserNotifications

struct TransactionAutomationSettingsView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @State private var transactionNotificationsEnabled = TransactionNotificationSettings().isEnabled
    @State private var notificationPermissionDenied = false
    @State private var showingWalletImport = false

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
                if budgetStore.currentBudgetId != nil {
                    Picker("Default Account", selection: $budgetStore.defaultAccountId) {
                        Text("None").tag(nil as String?)
                        ForEach(budgetStore.accounts.filter { !$0.closed }) { account in
                            Text(account.name).tag(account.id as String?)
                        }
                    }
                } else {
                    Text("Load a budget to choose a default account.")
                        .foregroundStyle(.secondary)
                }

                Toggle("Conventional Amount Entry", isOn: $budgetStore.conventionalAmountEntry)
            } header: {
                Text("Defaults")
            } footer: {
                Text("New transactions, Siri Shortcuts, and Wallet automation use the Default Account when no account is chosen. Conventional Amount Entry types 324 as 324.00 instead of filling cents first.")
            }

            Section("Transaction Behavior") {
                Picker("View Transactions As", selection: $budgetStore.transactionDisplayMode) {
                    ForEach(TransactionDisplayMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                Picker("Uncategorized Action", selection: $budgetStore.uncategorizedTapAction) {
                    ForEach(UncategorizedTapAction.allCases) { action in
                        Text(action.label).tag(action)
                    }
                }
            }

            Section {
                if budgetStore.payeeLocationWritesEnabled {
                    Toggle("Record Payee Locations", isOn: $budgetStore.recordPayeeLocations)

                    NavigationLink("Payee Locations") {
                        PayeeLocationsView()
                    }
                }

                if budgetStore.currentBudgetId != nil {
                    NavigationLink {
                        CardAccountMappingsView()
                    } label: {
                        HStack {
                            Text("Card & Account Mappings")
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
                            Text("Credit Cards & Billing Cycles")
                            Spacer()
                            let cardCount = budgetStore.activeCreditCardStatementDays.count
                            if cardCount > 0 {
                                Text("\(cardCount)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    NavigationLink("Rules") {
                        RulesListView()
                    }
                }

                if !budgetStore.payeeLocationWritesEnabled
                    && budgetStore.currentBudgetId == nil {
                    Text("Load a budget to manage transaction accounts and rules.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Payees & Accounts")
            } footer: {
                if !budgetStore.payeeLocationWritesEnabled
                    && budgetStore.currentBudgetId != nil
                    && budgetStore.isConnected {
                    Text("Payee locations require Actual Server 26.4.0 or later.")
                }
            }

            Section {
                NavigationLink {
                    SchedulesListView()
                } label: {
                    Label("Scheduled Transactions", systemImage: "calendar.badge.clock")
                }
            } header: {
                Text("Scheduled Transactions")
            } footer: {
                Text("Scheduled transactions that are due are posted automatically when the app opens — the same as opening the Actual web app. Transactions are created on your server.")
            }

            Section {
                Toggle("New Transaction Alerts", isOn: transactionNotificationsBinding)

                if notificationPermissionDenied {
                    Button("Open Settings to Allow Notifications") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                if notificationPermissionDenied {
                    Text("Notifications are turned off for Actuali in the Settings app, so transaction alerts can't be delivered.")
                } else {
                    Text("Get notified when transactions from bank sync or other devices arrive, so you can categorize them. iOS checks a few times a day and requires Background App Refresh.")
                }
            }

            Section {
                if budgetStore.currentBudgetId != nil {
                    NavigationLink {
                        CategoryFundingAutomationView()
                    } label: {
                        Label("Category Funding Settings", systemImage: "arrow.up.circle")
                    }
                } else {
                    Text("Load a budget to configure Category Funding.")
                        .foregroundStyle(.secondary)
                }

                NavigationLink {
                    BankSyncSetupView()
                } label: {
                    Label("Bank Sync (SimpleFIN)", systemImage: "building.columns")
                }

                NavigationLink {
                    WalletAutomationView()
                } label: {
                    Label("Log Wallet Payments Automatically", systemImage: "wallet.pass")
                }

                if WalletImportView.isSupported {
                    Button {
                        showingWalletImport = true
                    } label: {
                        Label("Import Wallet Transactions", systemImage: "square.and.arrow.down")
                    }
                }
            } header: {
                Text("Automations")
            } footer: {
                if WalletImportView.isSupported {
                    Text("Category Funding runs only for manual expenses entered from the selected account and funds only the required shortfall. You can also connect SimpleFIN, log tap-to-pay purchases from Apple Wallet, or import Apple Card, Apple Cash and Savings transactions.")
                } else {
                    Text("Category Funding runs only for manual expenses entered from the selected account and funds only the required shortfall. You can also connect SimpleFIN or log tap-to-pay purchases from Apple Wallet.")
                }
            }
        }
        .readableWidth()
        .navigationTitle("Transactions & Automation")
        .navigationBarTitleDisplayMode(.inline)
        .contentMargins(.horizontal, 6, for: .scrollContent)
        .task {
            await refreshNotificationPermissionState()
        }
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

    private func refreshNotificationPermissionState() async {
        guard transactionNotificationsEnabled else { return }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationPermissionDenied = status == .denied
    }
}
