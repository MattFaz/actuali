import SwiftUI

struct CategoryFundingAutomationView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @State private var configuration = CategoryFundingAutomationConfiguration()

    private var selectedAccountBinding: Binding<String?> {
        Binding(
            get: { configuration.accountId },
            set: {
                configuration.accountId = $0
                save()
            }
        )
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { configuration.isEnabled },
            set: {
                configuration.isEnabled = $0
                save()
            }
        )
    }

    private var fundingSourceBinding: Binding<CategoryFundingSource> {
        Binding(
            get: { configuration.fundingSource },
            set: {
                configuration.fundingSource = $0
                save()
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Automation", isOn: enabledBinding)
            } footer: {
                Text("When a new expense from the selected account would overdraw its category, Actuali automatically funds only the amount needed to cover that expense.")
            }

            Section("Trigger") {
                Picker("Account", selection: selectedAccountBinding) {
                    Text("None").tag(nil as String?)
                    ForEach(budgetStore.accounts.filter { !$0.closed }) { account in
                        Text(account.name).tag(account.id as String?)
                    }
                }
            }

            Section("Funding") {
                Picker("Funding Source", selection: fundingSourceBinding) {
                    ForEach(CategoryFundingSource.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }
            } footer: {
                Text("To Budget is used as the source. Only the shortfall is moved into the transaction's category.")
            }

            if configuration.isEnabled && configuration.accountId == nil {
                Section {
                    Label("Select an account to enable automatic funding.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Category Funding")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            configuration = CategoryFundingAutomationMonitor.loadConfiguration(for: budgetStore.currentBudgetId)
                ?? CategoryFundingAutomationConfiguration()
        }
    }

    private func save() {
        CategoryFundingAutomationMonitor.saveConfiguration(
            configuration,
            for: budgetStore.currentBudgetId
        )
    }
}

#Preview {
    NavigationStack {
        CategoryFundingAutomationView()
            .environmentObject(BudgetStore.previewInstance())
    }
}
