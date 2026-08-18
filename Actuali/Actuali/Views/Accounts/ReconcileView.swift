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
    
    /// Signed so a shortfall and a surplus read differently at a glance.
    private func differenceText(_ cents: Int) -> String {
        (cents > 0 ? "+" : "") + budgetStore.formatCurrency(cents)
    }
    
    /// Which of the mutually exclusive sections below the entry fields is
    /// showing. The section swap is animated off this rather than off
    /// `difference`, which recomputes on every keystroke — an implicit
    /// animation above a live text field would re-fire per character typed.
    private enum ComparisonSection: Equatable {
        case none
        case invalidAmount
        case difference
        case reconciled
    }

    private var comparisonSection: ComparisonSection {
        guard let difference else {
            return clearedBalance != nil && !balanceText.isEmpty ? .invalidAmount : .none
        }
        return difference == 0 ? .reconciled : .difference
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(String(localized: "reconcile.clearedBalance"))
                        Spacer()
                        if let clearedBalance {
                            // Deliberately bypasses the hide-balances mask:
                            // comparing exact amounts against the bank is the
                            // whole point of reconciling.
                            let text = budgetStore.formatCurrency(clearedBalance)
                            Text(text)
                                .fontWeight(.semibold)
                                .animatedAmount(text)
                        } else {
                            ProgressView()
                        }
                    }
                    HStack {
                        Text(String(localized: "reconcile.bankBalance"))
                        Spacer()
                        // Credit-card and overdrawn accounts reconcile against
                        // a negative bank balance, so the sign toggle is needed.
                        AmountInputField(
                            text: $balanceText,
                            conventionalAmountEntry: budgetStore.conventionalAmountEntry,
                            alignment: .right,
                            allowsNegative: true,
                            weight: .semibold
                        )
                    }
                } footer: {
                    Text(String(localized: "reconcile.balancePrompt"))
                }

                if let difference {
                    if difference == 0 {
                        Section {
                            Label(String(localized: "reconcile.allReconciled"), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Button {
                                Task { await lock() }
                            } label: {
                                HStack {
                                    Text(String(localized: "reconcile.lockCleared"))
                                    if isWorking {
                                        Spacer()
                                        ProgressView()
                                    }
                                }
                            }
                            .disabled(isWorking)
                            .accessibilityIdentifier("reconcile.lockCleared")
                        } footer: {
                            Text(String(localized: "reconcile.lockHelp"))
                        }
                    } else {
                        Section {
                            HStack {
                                Text(String(localized: "reconcile.difference"))
                                Spacer()
                                let text = differenceText(difference)
                                Text(text)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.orange)
                                    .animatedAmount(text)
                            }
                            Button {
                                Task { await createAdjustment(difference) }
                            } label: {
                                Text(String(localized: "reconcile.createAdjustment"))
                            }
                            .disabled(isWorking)
                        } footer: {
                            Text(String(format: String(localized: "reconcile.adjustmentHelp"), budgetStore.formatCurrency(difference)))
                        }
                    }
                } else if clearedBalance != nil && !balanceText.isEmpty {
                    Section {
                        Text(String(localized: "reconcile.invalidAmount"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // The moment the numbers meet, the difference section gives way
            // to "All reconciled!" — the one thing this screen exists to
            // show. The difference figure itself rolls on its own curve via
            // `animatedAmount`, so this only has to cover the swap.
            .animation(AppAnimation.appearance, value: comparisonSection)
            .navigationTitle(String(localized: "reconcile.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) { dismiss() }
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
