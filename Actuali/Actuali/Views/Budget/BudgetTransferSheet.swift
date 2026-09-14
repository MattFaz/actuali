import SwiftUI

/// Everything the move-money sheet needs, captured at tap time: the selected
/// category, if any, and the month it lives in. Identifiable so it can drive
/// `.sheet(item:)`.
struct BudgetTransferContext: Identifiable {
    let category: CategoryBudget?
    let budget: BudgetMonth

    init(category: CategoryBudget, budget: BudgetMonth) {
        self.category = category
        self.budget = budget
    }

    init(toBudgetIn budget: BudgetMonth) {
        category = nil
        self.budget = budget
    }

    var id: String { category?.id ?? "\(budget.id)-to-budget" }
    var amount: Int { category?.available ?? budget.toBudget ?? 0 }

    /// Covering ranks sources that can fully solve the problem first, then
    /// prefers the same group and the smallest sufficient balance. Partial
    /// sources follow largest-first. Moving a surplus keeps table order.
    var rankedCategories: [CategoryBudget] {
        let candidates = budget.categoryBudgets
            .filter { $0.categoryId != category?.categoryId }
            .filter { amount < 0 ? $0.available > 0 : true }
        guard amount < 0 else {
            return candidates.sorted {
                ($0.groupSortOrder, $0.categorySortOrder) < ($1.groupSortOrder, $1.categorySortOrder)
            }
        }
        let needed = abs(amount)
        return candidates.sorted { lhs, rhs in
            let lhsCovers = lhs.available >= needed
            let rhsCovers = rhs.available >= needed
            if lhsCovers != rhsCovers { return lhsCovers }
            let lhsSameGroup = lhs.groupId == category?.groupId
            let rhsSameGroup = rhs.groupId == category?.groupId
            if lhsSameGroup != rhsSameGroup { return lhsSameGroup }
            if lhs.available != rhs.available {
                return lhsCovers ? lhs.available < rhs.available : lhs.available > rhs.available
            }
            return (lhs.groupSortOrder, lhs.categorySortOrder)
                < (rhs.groupSortOrder, rhs.categorySortOrder)
        }
    }

    var canUseToBudget: Bool {
        guard let category, let toBudget = budget.toBudget else { return false }
        return category.available < 0 ? toBudget > 0 : true
    }
}

enum BudgetTransferLocalization {
    nonisolated static func candidateLabel(
        categoryName: String,
        amount: String,
        isRecommended: Bool,
        locale: Locale,
        bundle: Bundle = .main
    ) -> String {
        if isRecommended {
            return String(localized: LocalizedStringResource(
                "Recommended: \(categoryName) (\(amount))",
                locale: locale,
                bundle: bundle
            ))
        }
        return String(localized: LocalizedStringResource(
            "\(categoryName) (\(amount))",
            locale: locale,
            bundle: bundle
        ))
    }
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
    @Environment(\.locale) private var locale
    let context: BudgetTransferContext

    /// The other side of the move: the month's unallocated pool, or a
    /// category. A selected category is the counterpart; otherwise To Budget
    /// is the counterpart.
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
        let hasToBudget = context.canUseToBudget
        let firstCategory = context.rankedCategories.first.map { Endpoint.category($0.categoryId) }
        _endpoint = State(initialValue: hasToBudget ? .toBudget : (firstCategory ?? .toBudget))
        // Prefill with the full amount in play: the overspending to cover,
        // or the surplus available to move.
        _amountText = State(initialValue: String(format: "%.2f", Double(abs(context.amount)) / 100.0))
    }

    private var isCovering: Bool {
        context.amount < 0
    }

    private var eligibleCategories: [CategoryBudget] {
        context.rankedCategories
    }

    private var hasOptions: Bool {
        context.canUseToBudget || !eligibleCategories.isEmpty
    }

    /// Clamped to the amount actually being covered: this month's budget can
    /// offset part of the rolled-over overspending, and the breakdown must
    /// never show more than the "Amount to cover" total above it.
    private var rolledOverAmount: Int {
        guard let category = context.category else { return 0 }
        return min(abs(category.rolledOverOverspending), abs(category.available))
    }

    private var currentMonthShortfall: Int {
        max(0, abs(context.amount) - rolledOverAmount)
    }

    private var sourceAvailable: Int? {
        if !isCovering { return context.amount }
        if case .category(let id) = endpoint {
            return eligibleCategories.first(where: { $0.categoryId == id })?.available
        }
        return context.budget.toBudget
    }

    var body: some View {
        NavigationStack {
            Form {
                if isCovering, let category = context.category {
                    Section {
                        LabeledContent(String(localized: "Amount to cover")) {
                            Text(budgetStore.displayBalance(abs(category.available)))
                                .foregroundStyle(.red)
                        }
                        if currentMonthShortfall > 0 {
                            LabeledContent(String(localized: "This month")) {
                                Text(budgetStore.displayBalance(currentMonthShortfall))
                            }
                        }
                        if rolledOverAmount > 0 {
                            LabeledContent(String(localized: "From earlier months")) {
                                Text(budgetStore.displayBalance(rolledOverAmount))
                            }
                        }
                    } footer: {
                        Text("Covering moves budgeted money only. It does not change or duplicate any transactions.")
                    }
                }

                Section {
                    if hasOptions {
                        Picker(isCovering ? "From" : "To", selection: $endpoint) {
                            if context.canUseToBudget, let toBudget = context.budget.toBudget {
                                Text(String(format: String(localized: "To Budget (%@)"), budgetStore.displayBalance(toBudget)))
                                    .tag(Endpoint.toBudget)
                            }
                            ForEach(Array(eligibleCategories.enumerated()), id: \.element.id) { index, candidate in
                                Text(BudgetTransferLocalization.candidateLabel(
                                    categoryName: candidate.categoryName,
                                    amount: budgetStore.displayBalance(candidate.available),
                                    isRecommended: index == 0 && isCovering,
                                    locale: locale
                                ))
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
                    Text(isCovering ? String(localized: "Cover from") : String(localized: "Move to"))
                } footer: {
                    if let category = context.category {
                        Text(isCovering
                             ? "\(category.categoryName) is overspent by \(budgetStore.displayBalance(abs(category.available))) in \(MonthPicker.title(for: category.month))."
                             : "\(category.categoryName) has \(budgetStore.displayBalance(category.available)) available in \(MonthPicker.title(for: category.month)).")
                    }
                }

                Section {
                    AmountInputField(
                        text: $amountText,
                        conventionalAmountEntry: budgetStore.conventionalAmountEntry
                    )
                } header: {
                    Text("Amount")
                } footer: {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isCovering ? String(localized: "Cover Overspending") : String(localized: "Move Money"))
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
        .presentationDetents([.fraction(0.70), .large])
        .interactiveDismissDisabled(isSaving)
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                let cents = try BudgetStore.budgetAmountCents(from: amountText)
                if let sourceAvailable, cents > sourceAvailable {
                    throw BudgetStoreError.transferAmountExceedsSource
                }
                // Covering pulls money into the tapped category; moving a
                // surplus pushes money out of it.
                let categoryId = context.category?.categoryId
                let from = isCovering ? endpoint.categoryId : categoryId
                let to = isCovering ? categoryId : endpoint.categoryId
                try await budgetStore.transferBudget(
                    month: context.budget.month,
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
