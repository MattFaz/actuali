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

    /// Only categories with money available can be selected as a funding
    /// source. The automation re-checks the balance in the transaction's
    /// month before performing the transfer.
    private var availableFundingCategories {
        (budgetStore.currentBudgetMonth?.allCategoryBudgets ?? [])
            .filter { $0.available > 0 }
            .sorted {
                $0.categoryName.localizedCaseInsensitiveCompare($1.categoryName) == .orderedAscending
            }
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
                    Text("To Budget").tag(CategoryFundingSource.toBudget)

                    ForEach(availableFundingCategories, id: \.categoryId) { category in
                        Text(category.categoryName)
                            .tag(CategoryFundingSource.category(category.categoryId))
                    }
                }
            } header: {
                Text("Funding")
            } footer: {
                Text("To Budget is the default. You can also fund the category from another budget category that currently has a positive available balance.")
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
        .onChange(of: configuration.fundingSource) { _, newSource in
            if case .category(let categoryId) = newSource,
               !availableFundingCategories.contains(where: { $0.categoryId == categoryId }) {
                configuration.fundingSource = .toBudget
            }
            save()
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
