import SwiftUI

/// Explains the Budget tab's overspent badge (GH #138): every category in
/// the red for the displayed month, worst first. Reads the live month from
/// the store rather than a snapshot so fixing a category (via the pushed
/// transaction list, or a sync) updates the list on the way back.
struct OverspentCategoriesView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @State private var transferContext: BudgetTransferContext?
    @State private var editingCategory: CategoryBudget?

    var body: some View {
        Group {
            if let budget = budgetStore.currentBudgetMonth,
               !budget.overspentCategories.isEmpty {
                List {
                    Section {
                        ForEach(budget.overspentCategories) { category in
                            VStack(alignment: .leading, spacing: 10) {
                                OverspentCategoryRow(category: category)
                                Button {
                                    if budget.isTrackingBudget {
                                        editingCategory = category
                                    } else {
                                        transferContext = BudgetTransferContext(category: category, budget: budget)
                                    }
                                } label: {
                                    Label(
                                        budget.isTrackingBudget ? "Increase Budget" : "Cover Overspending",
                                        systemImage: budget.isTrackingBudget ? "plus.circle.fill" : "arrow.left.arrow.right"
                                    )
                                }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("Resolve overspending for \(category.categoryName)")
                            }
                                // Keep the existing shortcut in addition to
                                // the visible action for experienced users.
                                // Same resolution as the button: tracking
                                // budgets edit the amount, envelopes cover.
                                .swipeActions(edge: .trailing) {
                                    Button {
                                        if budget.isTrackingBudget {
                                            editingCategory = category
                                        } else {
                                            transferContext = BudgetTransferContext(category: category, budget: budget)
                                        }
                                    } label: {
                                        Label(
                                            budget.isTrackingBudget ? "Adjust" : "Cover",
                                            systemImage: budget.isTrackingBudget ? "plus.circle.fill" : "arrow.left.arrow.right"
                                        )
                                    }
                                    .tint(.green)
                                }
                        }
                    } footer: {
                        Text("Categories with a negative balance in \(MonthPicker.title(for: budget.month)). Balances include overspending rolled over from earlier months. Use the action under a category to resolve it, or open the category to review its transactions.")
                    }
                }
                .sheet(item: $transferContext) { context in
                    BudgetTransferSheet(context: context)
                }
                .sheet(item: $editingCategory) { category in
                    EditBudgetAmountSheet(category: category)
                }
            } else {
                ContentUnavailableView(
                    "Nothing Overspent",
                    systemImage: "checkmark.circle",
                    description: Text("No categories are overspent this month.")
                )
            }
        }
        .readableWidth()
        // Covering a category removes its row, and covering the last one
        // swaps the list for "Nothing Overspent" — the payoff for the swipe
        // action, so let it play rather than blink.
        .animation(AppAnimation.appearance, value: budgetStore.currentBudgetMonth?.overspentCount)
        .navigationTitle("Overspent Categories")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One overspent category: name, group, and the negative balance, with a
/// caption attributing any part that rolled over from earlier months.
/// Tapping pushes the month's transactions — the same list as the budget
/// table's "Spent" cell — to explain the in-month portion.
struct OverspentCategoryRow: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let category: CategoryBudget

    var body: some View {
        let available = budgetStore.displayBalance(category.available)
        NavigationLink {
            CategoryTransactionsView(
                destination: CategoryTransactionsDestination(
                    categoryId: category.categoryId,
                    categoryName: category.categoryName,
                    month: category.month
                )
            )
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(category.categoryName)
                    Spacer()
                    Text(budgetStore.displayBalance(category.available))
                        .foregroundStyle(.red)
                        .monospacedDigit()
                        .animatedAmount(available)    
                }
                Text(category.groupName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if category.rolledOverOverspending < 0 {
                    Label {
                        Text("Includes \(budgetStore.displayBalance(abs(category.rolledOverOverspending))) rolled over from earlier months")
                    } icon: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        OverspentCategoriesView()
    }
    .environmentObject(BudgetStore.previewInstance())
}
