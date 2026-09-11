import SwiftUI

/// Move positive To Budget into a category, or cover a negative To Budget from
/// a category with available funds.
struct BudgetToCategorySheet: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss

    let budget: BudgetMonth
    let amount: Int
    let isCovering: Bool
    @State private var selectedCategoryId: String
    @State private var amountText: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(budget: BudgetMonth, amount: Int, isCovering: Bool) {
        self.budget = budget
        self.amount = abs(amount)
        self.isCovering = isCovering
        let candidates = budget.categoryBudgets.filter { isCovering ? $0.available > 0 : true }
        _selectedCategoryId = State(initialValue: candidates.first?.categoryId ?? "")
        _amountText = State(initialValue: String(format: "%.2f", Double(abs(amount)) / 100.0))
    }

    private var candidates: [CategoryBudget] {
        budget.categoryBudgets.filter { isCovering ? $0.available > 0 : true }
    }

    var body: some View {
        NavigationStack {
            Form {
                if candidates.isEmpty {
                    Section {
                        Text(
                            isCovering
                                ? String(localized: "There are no categories with available funds to cover this overbudgeted amount.")
                                : String(localized: "There are no categories available to move this money into.")
                        )
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Section(
                        isCovering
                            ? String(localized: "Cover from a category")
                            : String(localized: "Move to a category")
                    ) {
                        Picker(
                            isCovering
                                ? String(localized: "From")
                                : String(localized: "To"),
                            selection: $selectedCategoryId
                        ) {
                            ForEach(candidates, id: \.categoryId) { category in
                                HStack {
                                    Text(category.categoryName)
                                    Spacer()
                                    Text(budgetStore.displayBalance(category.available))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                .tag(category.categoryId)
                            }
                        }

                        AmountInputField(
                            text: $amountText,
                            conventionalAmountEntry: budgetStore.conventionalAmountEntry,
                            allowsNegative: false,
                            autofocus: true
                        )
                    }

                    if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle(
                isCovering
                    ? String(localized: "Cover Overbudgeted")
                    : String(localized: "Move to Category")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCovering ? String(localized: "Cover") : String(localized: "Move")) {
                        save()
                    }
                    .disabled(isSaving || candidates.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isSaving)
    }

    private func save() {
        guard !isSaving else { return }
        errorMessage = nil
        isSaving = true
        Task {
            do {
                let cents = try BudgetStore.budgetAmountCents(from: amountText)
                guard cents > 0 else { throw BudgetStoreError.invalidAmount }
                guard let category = candidates.first(where: { $0.categoryId == selectedCategoryId }) else {
                    throw BudgetStoreError.invalidAmount
                }

                if isCovering {
                    guard cents <= category.available else {
                        throw BudgetStoreError.invalidAmount
                    }
                    try await budgetStore.transferBudget(
                        month: budget.month,
                        fromCategoryId: category.categoryId,
                        toCategoryId: nil,
                        amountCents: cents
                    )
                } else {
                    guard cents <= amount else { throw BudgetStoreError.invalidAmount }
                    try await budgetStore.transferBudget(
                        month: budget.month,
                        fromCategoryId: nil,
                        toCategoryId: category.categoryId,
                        amountCents: cents
                    )
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
