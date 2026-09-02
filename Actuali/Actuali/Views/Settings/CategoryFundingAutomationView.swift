import SwiftUI

struct CategoryFundingAutomationView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @State private var configuration = CategoryFundingAutomationConfiguration()

    /// Every non-income category is a valid configured source. The automation
    /// checks the source balance again for the transaction's own month, so the
    /// settings screen must not depend on the month the Budget tab is viewing.
    private var fundingCategories: [Category] {
        budgetStore.categoryGroups
            .flatMap(\.categories)
            .filter { !$0.isIncome && !$0.hidden }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    var body: some View {
        Form {
            Section {
                Picker("Account", selection: $configuration.accountId) {
                    Text("None").tag(String?.none)
                    ForEach(budgetStore.accounts.filter { !$0.closed && !$0.offBudget }, id: \.id) { account in
                        Text(account.name).tag(Optional(account.id))
                    }
                }
            } header: {
                Text("Trigger")
            }

            Section {
                Toggle("Enable Automation", isOn: $configuration.isEnabled)
                    .disabled(configuration.accountId == nil)
            } footer: {
                Text("When a new expense is manually entered from the selected account and would overdraw its category, Actuali automatically funds only the amount needed to cover that expense.")
            }

            Section {
                Picker("Funding Source", selection: $configuration.fundingSource) {
                    Text("To Budget").tag(CategoryFundingSource.toBudget)

                    ForEach(fundingCategories, id: \.id) { category in
                        Text(category.name)
                            .tag(CategoryFundingSource.category(category.id))
                    }
                }
            } header: {
                Text("Funding")
            } footer: {
                Text("To Budget is the default. You can also fund the category from another budget category that has available money.")
            }
        }
        .navigationTitle("Category Funding")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            configuration = CategoryFundingAutomation.loadConfiguration(for: budgetStore.currentBudgetId)
                ?? CategoryFundingAutomationConfiguration()
        }
        .onChange(of: configuration.accountId) { _, accountId in
            if accountId == nil {
                configuration.isEnabled = false
            }
        }
        .onChange(of: configuration) { _, _ in
            save()
        }
    }

    private func save() {
        CategoryFundingAutomation.saveConfiguration(
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
