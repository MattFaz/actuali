import SwiftUI

/// PWA-equivalent editor for an envelope budget's manual next-month buffer.
struct BudgetBufferSheet: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss

    let month: String
    let available: Int
    @State private var amountText: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(month: String, available: Int) {
        self.month = month
        self.available = available
        _amountText = State(initialValue: available > 0
            ? String(format: "%.2f", Double(available) / 100.0)
            : "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AmountInputField(
                        text: $amountText,
                        conventionalAmountEntry: budgetStore.conventionalAmountEntry,
                        allowsNegative: false,
                        autofocus: true
                    )
                } header: {
                    Text(String(localized: "Hold this amount"))
                } footer: {
                    Text(String(localized: "This amount will be removed from this month's To Budget and available to budget next month."))
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(String(localized: "Hold for next month"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Hold")) { save() }
                        .disabled(isSaving)
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
                let cents = try BudgetStore.budgetAmountCents(
                    from: amountText.isEmpty ? "0" : amountText
                )
                try await budgetStore.holdBudgetForNextMonth(
                    month: month,
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
