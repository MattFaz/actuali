import SwiftUI

/// Sheet showing pending transaction imports queued from shared messages.
/// Users can approve (logs to budget), edit (opens add-transaction form),
/// or dismiss each import.
struct PendingImportsView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @ObservedObject private var store = PendingImportStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var editingItem: PendingImport?
    @State private var errorMessage: String?
    @State private var isProcessing = false

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
                            Button {
                                editingItem = item
                            } label: {
                                PendingImportRow(item: item)
                            }
                            .buttonStyle(.plain)
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
                                    if isProcessing {
                                        ProgressView()
                                            .frame(maxWidth: .infinity)
                                    } else {
                                        Label("Approve All", systemImage: "checkmark.circle.fill")
                                            .frame(maxWidth: .infinity)
                                    }
                                }
                                .disabled(isProcessing)
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
            .alert("Import Failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") {}
            } message: {
                if let errorMessage {
                    Text(errorMessage)
                }
            }
            .sheet(item: $editingItem) { item in
                NavigationStack {
                    editView(for: item)
                }
            }
        }
    }

    // MARK: - Actions

    private func approve(_ item: PendingImport) {
        // Ignore a per-row swipe while Approve All is running: both paths log
        // and remove by id, so overlapping them could log the same item twice.
        guard !isProcessing else { return }
        let approver = PendingImportApprover(store: budgetStore)
        Task {
            do {
                _ = try await approver.approve(item)
                await MainActor.run {
                    withAnimation { store.remove(id: item.id) }
                }
            } catch PendingImportApprover.ApproveError.noAccountAvailable {
                // Can't confidently pick an account (no card match, no default).
                // Send the user to the review form to choose one rather than
                // dead-ending on an error — same destination as tapping the row.
                await MainActor.run { editingItem = item }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func approveAll() {
        let approver = PendingImportApprover(store: budgetStore)
        let items = store.imports
        isProcessing = true

        Task {
            var failedCount = 0
            for item in items {
                do {
                    _ = try await approver.approve(item)
                    await MainActor.run {
                        withAnimation { store.remove(id: item.id) }
                    }
                } catch {
                    failedCount += 1
                }
            }
            await MainActor.run {
                isProcessing = false
                if failedCount > 0 {
                    errorMessage = "\(failedCount) transaction(s) could not be approved. Please check their details."
                }
            }
        }
    }

    @ViewBuilder
    private func editView(for item: PendingImport) -> some View {
        let targetAccountId = resolveAccountId(for: item)
        if let accountId = targetAccountId {
            AddTransactionView(
                accountId: accountId,
                payee: item.payee ?? "",
                amountCents: item.amount.flatMap { Transaction.cents(fromDollars: $0) },
                date: item.date,
                notes: item.rawText,
                categoryId: nil,
                isIncome: item.isIncome,
                cleared: false,
                onSaved: { store.remove(id: item.id) }
            )
            .environmentObject(budgetStore)
        } else {
            ContentUnavailableView(
                "No Accounts",
                systemImage: "banknote",
                description: Text("Please add an account before editing this import.")
            )
        }
    }

    private func resolveAccountId(for item: PendingImport) -> String? {
        guard let hint = item.cardHint, !hint.isEmpty else { return nil }
        return BudgetStore.resolveAccountId(
            hint: hint,
            accounts: budgetStore.accounts,
            cardMappings: budgetStore.cardAccountMappings
        )
    }
}

// MARK: - Row

private struct PendingImportRow: View {
    let item: PendingImport

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

            if !item.rawText.isEmpty {
                Text(item.rawText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private func amountString(_ amount: Double, isIncome: Bool) -> String {
        let sign = isIncome ? "+" : "-"
        return "\(sign)\(String(format: "%.2f", amount))"
    }
}
