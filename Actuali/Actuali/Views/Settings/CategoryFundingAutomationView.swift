import SwiftUI

struct CategoryFundingAutomationView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @State private var configuration = CategoryFundingAutomationConfiguration()

    private var selectedAccountBinding: Binding<String?> {
        Binding<String?>(
            get: { configuration.accountId },
            set: {
                configuration.accountId = $0
                save()
            }
        )
    }

    private var enabledBinding: Binding<Bool> {
        Binding<Bool>(
            get: { configuration.isEnabled },
            set: {
                configuration.isEnabled = $0
                save()
            }
        )
    }

    private var fundingSourceBinding: Binding<CategoryFundingSource> {
        Binding<CategoryFundingSource>(
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

            Section {
                Picker("Account", selection: selectedAccountBinding) {
                    Text("None").tag(String?.none)
                    ForEach(budgetStore.accounts.filter { !$0.closed }, id: \.id) { account in
                        Text(account.name).tag(Optional(account.id))
                    }
                }
            } header: {
                Text("Trigger")
            }

            Section {
                Picker("Funding Source", selection: fundingSourceBinding) {
                    ForEach(CategoryFundingSource.allCases, id: \.id) { source in
                        Text(source.label).tag(source)
                    }
                }
            } header: {
                Text("Funding")
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
