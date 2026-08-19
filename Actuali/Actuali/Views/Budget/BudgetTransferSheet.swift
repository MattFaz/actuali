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
        let hasToBudget = Self.canUseToBudget(context)
        let firstCategory = Self.rankedCategories(context).first.map { Endpoint.category($0.categoryId) }
        _endpoint = State(initialValue: hasToBudget ? .toBudget : (firstCategory ?? .toBudget))
        // Prefill with the full amount in play: the overspending to cover,
        // or the surplus available to move.
        _amountText = State(initialValue: String(format: "%.2f", Double(abs(context.category.available)) / 100.0))
    }

    private var isCovering: Bool {
        context.category.available < 0
    }

    /// Covering ranks sources that can fully solve the problem first, then
    /// prefers the same group and the smallest sufficient balance. Partial
    /// sources follow largest-first. Moving a surplus keeps table order.
    static func rankedCategories(_ context: BudgetTransferContext) -> [CategoryBudget] {
        let candidates = context.budget.categoryBudgets
            .filter { $0.categoryId != context.category.categoryId }
            .filter { context.category.available < 0 ? $0.available > 0 : true }
        guard context.category.available < 0 else {
            return candidates.sorted {
                ($0.groupSortOrder, $0.categorySortOrder) < ($1.groupSortOrder, $1.categorySortOrder)
            }
        }
        let needed = abs(context.category.available)
        return candidates.sorted { lhs, rhs in
            let lhsCovers = lhs.available >= needed
            let rhsCovers = rhs.available >= needed
            if lhsCovers != rhsCovers { return lhsCovers }
            let lhsSameGroup = lhs.groupId == context.category.groupId
            let rhsSameGroup = rhs.groupId == context.category.groupId
            if lhsSameGroup != rhsSameGroup { return lhsSameGroup }
            if lhs.available != rhs.available {
                return lhsCovers ? lhs.available < rhs.available : lhs.available > rhs.available
            }
            return (lhs.groupSortOrder, lhs.categorySortOrder)
                < (rhs.groupSortOrder, rhs.categorySortOrder)
        }
    }

    static func canUseToBudget(_ context: BudgetTransferContext) -> Bool {
        guard let toBudget = context.budget.toBudget else { return false }
        return context.category.available < 0 ? toBudget > 0 : true
    }

    private var eligibleCategories: [CategoryBudget] {
        Self.rankedCategories(context)
    }

    private var hasOptions: Bool {
        Self.canUseToBudget(context) || !eligibleCategories.isEmpty
    }

    /// Clamped to the amount actually being covered: this month's budget can
    /// offset part of the rolled-over overspending, and the breakdown must
    /// never show more than the "Amount to cover" total above it.
    private var rolledOverAmount: Int {
        min(abs(context.category.rolledOverOverspending), abs(context.category.available))
    }

    private var currentMonthShortfall: Int {
        max(0, abs(context.category.available) - rolledOverAmount)
    }

    private var selectedSourceAvailable: Int? {
        switch endpoint {
        case .toBudget:
            return context.budget.toBudget
        case .category(let id):
            return eligibleCategories.first(where: { $0.categoryId == id })?.available
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if isCovering {
                    Section {
                        LabeledContent("Amount to cover") {
                            Text(budgetStore.displayBalance(abs(context.category.available)))
                                .foregroundStyle(.red)
                        }
                        if currentMonthShortfall > 0 {
                            LabeledContent("This month") {
                                Text(budgetStore.displayBalance(currentMonthShortfall))
                            }
                        }
                        if rolledOverAmount > 0 {
                            LabeledContent("From earlier months") {
                                Text(budgetStore.displayBalance(rolledOverAmount))
                            }
                        }
                    } footer: {
                        Text("Covering moves budgeted money only. It does not change or duplicate any transactions.")
                    }
                }

                Section {
                    if hasOptions {
                        Picker(isCovering ? String(localized: "budget.transfer.from") : String(localized: "budget.transfer.to"), selection: $endpoint) {
                            if Self.canUseToBudget(context), let toBudget = context.budget.toBudget {
                                Text(String(format: String(localized: "budget.transfer.toBudget"), budgetStore.displayBalance(toBudget)))
                                    .tag(Endpoint.toBudget)
                            }
                            ForEach(Array(eligibleCategories.enumerated()), id: \.element.id) { index, candidate in
                                Text("\(index == 0 && isCovering ? "Recommended: " : "")\(candidate.categoryName) (\(budgetStore.displayBalance(candidate.available)))")
                                    .tag(Endpoint.category(candidate.categoryId))
                            }
                        }
                    } else {
                        Text(isCovering
                            ? "Nothing can cover this right now: To Budget is empty and no other category has available funds."
                            : "There are no other categories to move this to.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(isCovering ? String(localized: "budget.transfer.coverFrom") : String(localized: "budget.transfer.moveTo"))
                } footer: {
                    Text(isCovering
                         ? String(format: String(localized: "budget.transfer.overspentFooter"), context.category.categoryName, budgetStore.displayBalance(abs(context.category.available)), MonthPicker.title(for: context.category.month))
                         : String(format: String(localized: "budget.transfer.availableFooter"), context.category.categoryName, budgetStore.displayBalance(context.category.available), MonthPicker.title(for: context.category.month)))
                }

                Section {
                    AmountInputField(
                        text: $amountText,
                        conventionalAmountEntry: budgetStore.conventionalAmountEntry
                    )
                } header: {
                    Text(String(localized: "common.amount"))
                } footer: {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isCovering ? String(localized: "budget.transfer.coverOverspending") : String(localized: "budget.transfer.moveMoney"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "budget.transfer.move")) { save() }
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
                if isCovering, let selectedSourceAvailable, cents > selectedSourceAvailable {
                    throw BudgetStoreError.transferAmountExceedsSource
                }
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
