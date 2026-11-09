import SwiftUI

struct TransactionAutomationSettingsView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    @State private var showingWalletImport = false

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

            Section {
                Picker(String(localized: "View Transactions As"), selection: $budgetStore.transactionDisplayMode) {
                    ForEach(TransactionDisplayMode.allCases) { mode in
                        Text(mode.label(locale: locale)).tag(mode)
                    }
                }

                Picker(String(localized: "Uncategorized Action"), selection: $budgetStore.uncategorizedTapAction) {
                    ForEach(UncategorizedTapAction.allCases) { action in
                        Text(action.label(locale: locale)).tag(action)
                    }
                }

                Toggle(String(localized: "Category from Payee History"), isOn: $budgetStore.suggestCategoryFromPayeeHistory)
                    .accessibilityIdentifier("transactionAutomation.categoryFromPayeeHistory")
                Toggle(String(localized: "Show Balance Impact"), isOn: $budgetStore.showTransactionImpactCue)
                    .accessibilityIdentifier("transactionAutomation.showBalanceImpact")
            } header: {
                Text(String(localized: "Transaction Behavior"))
            } footer: {
                Text(String(localized: "Category from Payee History gives a new transaction the category of the last transaction at the same payee when no category is chosen. Rules still run after it."))
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
                                Text("\(CardAccountMappingsView.mappedAccountCount(cardMappings: budgetStore.cardAccountMappings))")
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

                if !budgetStore.payeeLocationWritesEnabled,
                   budgetStore.currentBudgetId == nil {
                    Text(String(localized: "Load a budget to manage transaction accounts."))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(String(localized: "Payees & Accounts"))
            } footer: {
                if !budgetStore.payeeLocationWritesEnabled,
                   budgetStore.currentBudgetId != nil,
                   budgetStore.isConnected {
                    Text(String(localized: "Payee locations require Actual Server 26.4.0 or later."))
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

            // Mirrors the web's Settings → Experimental features toggle. These
            // are synced preferences shared with the web app.
            Section {
                Toggle(String(localized: "Budget Goal Templates"), isOn: Binding(
                    get: { budgetStore.goalTemplatesEnabled },
                    set: { enabled in
                        Task { await budgetStore.setGoalTemplatesEnabled(enabled) }
                    }
                ))
                .accessibilityIdentifier("transactionAutomation.goalTemplates")
                .disabled(budgetStore.currentBudgetId == nil)
                Toggle(String(localized: "Automations Editor"), isOn: Binding(
                    get: { budgetStore.goalTemplatesUIEnabled },
                    set: { enabled in
                        Task { await budgetStore.setGoalTemplatesUIEnabled(enabled) }
                    }
                ))
                .accessibilityIdentifier("transactionAutomation.automationsEditor")
                .disabled(budgetStore.currentBudgetId == nil || !budgetStore.goalTemplatesEnabled)
            } header: {
                Text(String(localized: "Experimental"))
            } footer: {
                Text(String(localized: "Set budgeting goals per category with #template and #goal lines in category notes, or with the visual automations editor, then apply them from the Budget tab's options menu. Synced with the web app's Goal Templates experimental features."))
            }
        }
        .readableWidth()
        .navigationTitle(String(localized: "Transactions & Automation"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingWalletImport) {
            WalletImportView()
                .environmentObject(budgetStore)
        }
    }
}
