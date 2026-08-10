import SwiftUI

/// Everything the move-money sheet needs, captured at tap time: the category
/// whose balance was tapped and the month it lives in (for the picker's
/// category list and To Budget figure). Identifiable so it can drive
/// `.sheet(item:)`.
struct BudgetTransferContext: Identifiable {
    let category: CategoryBudget
    let budget: BudgetMonth
    var id: String { category.id }
}

/// Move budgeted funds between categories (GH #128). Adapts to the tapped
/// balance: in the red it covers the overspending from "To Budget" or a
/// category with available funds; in the green it sends the surplus to
/// another category or back to "To Budget". Mirrors Actual web's
/// cover-overspending / transfer flows — the write is just a paired budgeted
/// adjustment, so the sheet saves through the sync engine and refreshes the
/// month.
struct BudgetTransferSheet: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let context: BudgetTransferContext

    /// The other side of the move: the month's unallocated pool, or a
    /// category. (The tapped category is always this side's counterpart.)
    enum Endpoint: Hashable {
        case toBudget
        case category(String)

        var categoryId: String? {
            switch self {
            case .toBudget: return nil
            case .category(let id): return id
            }
        }
    }

    @State private var endpoint: Endpoint
    @State private var amountText: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(context: BudgetTransferContext) {
        self.context = context
        // Overspent: default to covering from To Budget (like the web UI);
        // tracking budgets have no To Budget, so fall back to the first
        // category with funds. Surplus: default to sending back to To Budget.
        let hasToBudget = context.budget.toBudget != nil
        let firstCategory = Self.eligibleCategories(context).first.map { Endpoint.category($0.categoryId) }
        _endpoint = State(initialValue: hasToBudget ? .toBudget : (firstCategory ?? .toBudget))
        // Prefill with the full amount in play: the overspending to cover,
        // or the surplus available to move.
        _amountText = State(initialValue: String(format: "%.2f", Double(abs(context.category.available)) / 100.0))
    }

    private var isCovering: Bool {
        context.category.available < 0
    }

    /// Categories offered on the other side, in the budget table's order.
    /// Covering only lists categories that have funds to give; a surplus can
    /// go to any other category, including one at zero.
    private static func eligibleCategories(_ context: BudgetTransferContext) -> [CategoryBudget] {
        context.budget.categoryBudgets
            .filter { $0.categoryId != context.category.categoryId }
            .filter { context.category.available < 0 ? $0.available > 0 : true }
            .sorted {
                ($0.groupSortOrder, $0.categorySortOrder) < ($1.groupSortOrder, $1.categorySortOrder)
            }
    }

    private var eligibleCategories: [CategoryBudget] {
        Self.eligibleCategories(context)
    }

    private var hasOptions: Bool {
        context.budget.toBudget != nil || !eligibleCategories.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if hasOptions {
                        Picker(isCovering ? "From" : "To", selection: $endpoint) {
                            if let toBudget = context.budget.toBudget {
                                Text("To Budget (\(budgetStore.displayBalance(toBudget)))")
                                    .tag(Endpoint.toBudget)
                            }
                            ForEach(eligibleCategories) { candidate in
                                Text("\(candidate.categoryName) (\(budgetStore.displayBalance(candidate.available)))")
                                    .tag(Endpoint.category(candidate.categoryId))
                            }
                        }
                    } else {
                        Text("No other category has available funds to cover this.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(isCovering ? "Cover from" : "Move to")
                } footer: {
                    Text(isCovering
                         ? "\(context.category.categoryName) is overspent by \(budgetStore.displayBalance(abs(context.category.available))) in \(MonthPicker.title(for: context.category.month))."
                         : "\(context.category.categoryName) has \(budgetStore.displayBalance(context.category.available)) available in \(MonthPicker.title(for: context.category.month)).")
                }

                Section {
                    AmountInputField(text: $amountText)
                } header: {
                    Text("Amount")
                } footer: {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isCovering ? "Cover Overspending" : "Move Money")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") { save() }
                        .disabled(isSaving || !hasOptions)
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(isSaving)
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                let cents = try BudgetStore.budgetAmountCents(from: amountText)
                // Covering pulls money into the tapped category; moving a
                // surplus pushes money out of it.
                let from = isCovering ? endpoint.categoryId : context.category.categoryId
                let to = isCovering ? context.category.categoryId : endpoint.categoryId
                try await budgetStore.transferBudget(
                    month: context.category.month,
                    fromCategoryId: from,
                    toCategoryId: to,
                    amountCents: cents
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

#Preview {
    BudgetTransferSheet(context: BudgetTransferContext(
        category: CategoryBudget(
            month: "2026-07",
            categoryId: "cat-1",
            categoryName: "Groceries",
            groupId: "grp-1",
            groupName: "Daily",
            groupSortOrder: 0,
            categorySortOrder: 0,
            budgeted: 5000,
            spent: -7500,
            available: -2500,
            carryover: 0
        ),
        budget: BudgetMonth(month: "2026-07", categoryBudgets: [], toBudget: 10000)
    ))
    .environmentObject(BudgetStore.previewInstance())
}
