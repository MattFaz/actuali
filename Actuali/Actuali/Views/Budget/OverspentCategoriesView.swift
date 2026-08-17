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
                                        Label(String(localized: "overspent.cover"), systemImage: "arrow.left.arrow.right")
                                    }
                                    .tint(.green)
                                }
                        }
                    } footer: {
                        Text(String(format: String(localized: "overspent.explanation"), MonthPicker.title(for: budget.month)))
                    }
                }
                .sheet(item: $transferContext) { context in
                    BudgetTransferSheet(context: context)
                }
            } else {
                ContentUnavailableView(
                    String(localized: "overspent.empty.title"),
                    systemImage: "checkmark.circle",
                    description: Text(String(localized: "overspent.empty.description"))
                )
            }
        }
        .readableWidth()
        // Covering a category removes its row, and covering the last one
        // swaps the list for "Nothing Overspent" — the payoff for the swipe
        // action, so let it play rather than blink.
        .animation(AppAnimation.appearance, value: budgetStore.currentBudgetMonth?.overspentCount)
        .navigationTitle(String(localized: "overspent.title"))
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
                        Text(String(format: String(localized: "overspent.rolledOver"), budgetStore.displayBalance(abs(category.rolledOverOverspending))))
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
