import SwiftUI

struct CategoryFundingAutomationView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @State private var configuration = CategoryFundingAutomationConfiguration()

    /// Categories with money, plus the saved source so a drained source is
    /// not silently replaced with To Budget. The automation re-checks the
    /// source balance when it actually runs.
    private var fundingCategories: [CategoryBudget] {
        var savedId: String?
        if case .category(let id) = configuration.fundingSource {
            savedId = id
        }

        return (budgetStore.currentBudgetMonth?.allCategoryBudgets ?? [])
            .filter { $0.available > 0 || $0.categoryId == savedId }
            .sorted {
                $0.categoryName.localizedCaseInsensitiveCompare($1.categoryName) == .orderedAscending
            }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Automation", isOn: $configuration.isEnabled)
            } footer: {
                Text("When a new expense from the selected account would overdraw its category, Actuali automatically funds only the amount needed to cover that expense.")
            }

            Section {
                Picker("Account", selection: $configuration.accountId) {
                    Text("None").tag(String?.none)
                    ForEach(budgetStore.accounts.filter { !$0.closed }, id: \.id) { account in
                        Text(account.name).tag(Optional(account.id))
                    }
                }
            } header: {
                Text("Trigger")
            }

            Section {
                Picker("Funding Source", selection: $configuration.fundingSource) {
                    Text("To Budget").tag(CategoryFundingSource.toBudget)

                    ForEach(fundingCategories, id: \.categoryId) { category in
                        Text(category.categoryName)
                            .tag(CategoryFundingSource.category(category.categoryId))
                    }
                }
            } header: {
                Text("Funding")
            } footer: {
                Text("To Budget is the default. You can also fund the category from another budget category that has available money.")
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
        .onChange(of: configuration) { _, _ in
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
