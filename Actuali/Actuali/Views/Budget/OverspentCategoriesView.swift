import SwiftUI

/// Explains the Budget tab's overspent badge (GH #138): every category in
/// the red for the displayed month, worst first. Reads the live month from
/// the store rather than a snapshot so fixing a category (via the pushed
/// transaction list, or a sync) updates the list on the way back.
struct OverspentCategoriesView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @State private var transferContext: BudgetTransferContext?

    var body: some View {
        Group {
            if let budget = budgetStore.currentBudgetMonth,
               !budget.overspentCategories.isEmpty {
                List {
                    Section {
                        ForEach(budget.overspentCategories) { category in
                            OverspentCategoryRow(category: category)
                                // The fix, right where the problem is listed
                                // (GH #128): swipe to cover the overspending
                                // from To Budget or another category.
                                .swipeActions(edge: .trailing) {
                                    Button {
                                        transferContext = BudgetTransferContext(category: category, budget: budget)
                                    } label: {
                                        Label("Cover", systemImage: "arrow.left.arrow.right")
                                    }
                                    .tint(.green)
                                }
                        }
                    } footer: {
                        Text("Categories with a negative balance in \(MonthPicker.title(for: budget.month)). Balances include overspending rolled over from earlier months, which this month's transactions alone won't explain. Swipe a category to cover its overspending.")
                    }
                }
                .sheet(item: $transferContext) { context in
                    BudgetTransferSheet(context: context)
                }
            } else {
                ContentUnavailableView(
                    "Nothing Overspent",
                    systemImage: "checkmark.circle",
                    description: Text("No categories are overspent this month.")
                )
            }
        }
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
