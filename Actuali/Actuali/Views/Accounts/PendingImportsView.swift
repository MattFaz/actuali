import SwiftUI

/// Sheet showing pending transaction imports queued from shared messages.
/// Users can approve (logs to budget), edit (opens add-transaction form),
/// or dismiss each import.
struct PendingImportsView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @ObservedObject private var store = PendingImportStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.imports.isEmpty {
                    ContentUnavailableView(
                        "No Pending Imports",
                        systemImage: "tray",
                        description: Text("Share a bank message to Actuali to import transactions")
                    )
                } else {
                    List {
                        ForEach(store.imports) { item in
                            PendingImportRow(item: item, onApprove: { approve(item) })
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        withAnimation { store.remove(id: item.id) }
                                    } label: {
                                        Label("Dismiss", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        approve(item)
                                    } label: {
                                        Label("Approve", systemImage: "checkmark")
                                    }
                                    .tint(.green)
                                }
                        }

                        if store.count > 1 {
                            Section {
                                Button {
                                    approveAll()
                                } label: {
                                    Label("Approve All", systemImage: "checkmark.circle.fill")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Pending Imports")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Actions

    private func approve(_ item: PendingImport) {
        Task {
            await logImport(item)
            await MainActor.run {
                withAnimation { store.remove(id: item.id) }
            }
        }
    }

    private func approveAll() {
        let items = store.imports
        Task {
            for item in items {
                await logImport(item)
            }
            await MainActor.run {
                withAnimation { store.removeAll() }
            }
        }
    }

    @MainActor
    private func logImport(_ item: PendingImport) async {
        guard let amount = item.amount, amount > 0 else { return }

        let store = budgetStore
        await store.ensureBudgetReady()

        // Resolve account from card hint, then default.
        var accountId: String?
        if let hint = item.cardHint, !hint.isEmpty {
            accountId = await store.resolveAccountId(hint: hint)
        }
        if accountId == nil {
            accountId = store.defaultAccountId
        }
        guard let resolvedAccountId = accountId else { return }

        // Verify the account is open.
        let accounts = await store.accountsForIntent()
        guard accounts.contains(where: { $0.id == resolvedAccountId && !$0.closed }) else { return }

        guard let cents = Transaction.cents(fromDollars: amount) else { return }
        let amountCents = item.isIncome ? cents : -cents

        do {
            let _ = try await TransactionLogger(store: store).logTransaction(
                accountId: resolvedAccountId,
                amountCents: amountCents,
                rawMerchant: item.payee ?? "Unknown",
                notes: nil,
                date: item.date,
                cleared: true
            )
        } catch {
            // ponytail: silent failure for now; the item stays removed.
            // Upgrade path: re-add with error state or show an alert.
        }
    }
}

// MARK: - Row

private struct PendingImportRow: View {
    let item: PendingImport
    let onApprove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.payee ?? "Unknown Payee")
                    .font(.headline)
                Spacer()
                if let amount = item.amount {
                    Text(amountString(amount, isIncome: item.isIncome))
                        .font(.headline)
                        .foregroundStyle(item.isIncome ? .green : .primary)
                }
            }

            HStack {
                if let hint = item.cardHint {
                    Text("Card ••\(hint)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(item.date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(item.rawText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }

    private func amountString(_ amount: Double, isIncome: Bool) -> String {
        let sign = isIncome ? "+" : "-"
        return "\(sign)\(String(format: "%.2f", amount))"
    }
}
