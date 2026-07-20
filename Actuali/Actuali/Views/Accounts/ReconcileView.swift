import SwiftUI

/// Reconcile an account against the real bank balance, mirroring Actual's
/// desktop flow: compare the entered bank balance to the account's cleared
/// balance, offer a balance-adjustment transaction while they differ, and
/// lock (mark reconciled) every cleared transaction once they match.
struct ReconcileView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let account: Account

    @State private var clearedBalance: Int?
    @State private var balanceText = ""
    @State private var isWorking = false

    /// The entered bank balance in cents, nil while unparseable. AmountParser
    /// absorbs locale separators and currency symbols the same way the
    /// Shortcuts path does.
    private var targetCents: Int? {
        guard let dollars = AmountParser.parse(balanceText) else { return nil }
        return Transaction.cents(fromDollars: dollars)
    }

    private var difference: Int? {
        guard let clearedBalance, let targetCents else { return nil }
        return targetCents - clearedBalance
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Cleared Balance")
                        Spacer()
                        if let clearedBalance {
                            // Deliberately bypasses the hide-balances mask:
                            // comparing exact amounts against the bank is the
                            // whole point of reconciling.
                            Text(budgetStore.formatCurrency(clearedBalance))
                                .fontWeight(.semibold)
                        } else {
                            ProgressView()
                        }
                    }
                    HStack {
                        Text("Bank Balance")
                        Spacer()
                        TextField("0.00", text: $balanceText)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .fontWeight(.semibold)
                    }
                } footer: {
                    Text("Enter the current balance of the bank account you want to reconcile with.")
                }

                if let difference {
                    if difference == 0 {
                        Section {
                            Label("All reconciled!", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Button {
                                Task { await lock() }
                            } label: {
                                HStack {
                                    Text("Lock Cleared Transactions")
                                    if isWorking {
                                        Spacer()
                                        ProgressView()
                                    }
                                }
                            }
                            .disabled(isWorking)
                        } footer: {
                            Text("Locking marks every cleared transaction as reconciled so it can't be changed by accident.")
                        }
                    } else {
                        Section {
                            HStack {
                                Text("Difference")
                                Spacer()
                                Text((difference > 0 ? "+" : "") + budgetStore.formatCurrency(difference))
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.orange)
                            }
                            Button {
                                Task { await createAdjustment(difference) }
                            } label: {
                                Text("Create Adjustment Transaction")
                            }
                            .disabled(isWorking)
                        } footer: {
                            Text("Your cleared balance needs \(budgetStore.formatCurrency(difference)) to match the bank. The adjustment is a cleared transaction for that amount; you can lock afterwards.")
                        }
                    }
                } else if clearedBalance != nil && !balanceText.isEmpty {
                    Section {
                        Text("Enter a valid amount to compare balances.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Reconcile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await loadClearedBalance(prefill: true) }
        }
    }

    private func loadClearedBalance(prefill: Bool) async {
        clearedBalance = await budgetStore.clearedBalance(accountId: account.id)
        if prefill, let clearedBalance, balanceText.isEmpty {
            // Plain editable number, not the currency-formatted string — the
            // field prefills to "already matches" like upstream's menu.
            balanceText = String(format: "%.2f", Double(clearedBalance) / 100.0)
        }
    }

    private func lock() async {
        isWorking = true
        defer { isWorking = false }
        await budgetStore.lockClearedTransactions(accountId: account.id)
        dismiss()
    }

    private func createAdjustment(_ diffCents: Int) async {
        isWorking = true
        defer { isWorking = false }
        if await budgetStore.createReconciliationAdjustment(
            accountId: account.id, amountCents: diffCents
        ) {
            // The cleared balance now includes the adjustment, so the
            // difference collapses to zero and the lock action appears.
            await loadClearedBalance(prefill: false)
        }
    }
}

#Preview {
    ReconcileView(
        account: Account(
            id: "1",
            name: "Checking",
            type: .checking,
            offBudget: false,
            closed: false,
            sortOrder: 0,
            balance: 245073
        )
    )
    .environmentObject(BudgetStore.previewInstance())
}
