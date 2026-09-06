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
                let visibleImports = store.visibleImports(for: budgetStore.currentBudgetId)
                if visibleImports.isEmpty {
                    ContentUnavailableView(
                        "No Pending Imports",
                        systemImage: "tray",
                        description: Text("Share a bank message to Actuali to import transactions")
                    )
                } else {
                    List {
                        ForEach(visibleImports) { item in
                            Button {
                                editingItem = item
                            } label: {
                                PendingImportRow(item: item)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    do { try store.remove(id: item.id) } catch { errorMessage = error.localizedDescription }
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

                        if visibleImports.count > 1 {
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
                    do { try store.remove(id: item.id) } catch { errorMessage = error.localizedDescription }
                }
            } catch PendingImportApprover.ApproveError.noAccountAvailable {
                // Can't confidently pick an account (no card match, no default).
                // Send the user to the review form to choose one rather than
                // dead-ending on an error — same destination as tapping the row.
                await MainActor.run { editingItem = item }
            } catch PendingImportApprover.ApproveError.budgetIdentityRequired {
                await MainActor.run { editingItem = item }
            } catch PendingImportApprover.ApproveError.budgetMismatch {
                await MainActor.run { editingItem = item }
            } catch PendingImportApprover.ApproveError.sourceCurrencyRequired {
                await MainActor.run { editingItem = item }
            } catch PendingImportApprover.ApproveError.sourceCurrencyMismatch {
                await MainActor.run { editingItem = item }
            } catch PendingImportApprover.ApproveError.alreadyApproved {
                await MainActor.run {
                    do { try store.remove(id: item.id) } catch { errorMessage = error.localizedDescription }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func approveAll() {
        let approver = PendingImportApprover(store: budgetStore)
        let items = store.visibleImports(for: budgetStore.currentBudgetId)
        isProcessing = true

        Task {
            var failedCount = 0
            var reviewCount = 0
            var reviewItem: PendingImport?
            for item in items {
                do {
                    _ = try await approver.approve(item)
                    await MainActor.run {
                        do { try store.remove(id: item.id) }
                        catch { errorMessage = error.localizedDescription }
                    }
                } catch PendingImportApprover.ApproveError.sourceCurrencyMismatch {
                    reviewCount += 1
                    reviewItem = reviewItem ?? item
                } catch PendingImportApprover.ApproveError.sourceCurrencyRequired,
                        PendingImportApprover.ApproveError.budgetIdentityRequired,
                        PendingImportApprover.ApproveError.budgetMismatch {
                    reviewCount += 1
                    reviewItem = reviewItem ?? item
                } catch {
                    failedCount += 1
                }
            }
            await MainActor.run {
                isProcessing = false
                if let reviewItem {
                    editingItem = reviewItem
                }
                if reviewCount > 0 {
                    errorMessage = Self.reviewRequiredMessage(count: reviewCount)
                } else if failedCount > 0 {
                    errorMessage = Self.approvalFailureMessage(count: failedCount)
                }
            }
        }
    }

    nonisolated static func reviewRequiredMessage(
        count: Int,
        locale: Locale = .autoupdatingCurrent,
        bundle: Bundle = .main
    ) -> String {
        let resource = LocalizedStringResource(
            "\(count) transactions require review and were left pending.",
            locale: locale,
            bundle: bundle
        )
        return String(localized: resource)
    }

    nonisolated static func approvalFailureMessage(
        count: Int,
        locale: Locale = .autoupdatingCurrent,
        bundle: Bundle = .main
    ) -> String {
        let resource = LocalizedStringResource(
            "\(count) transaction could not be approved. Please check its details.",
            locale: locale,
            bundle: bundle
        )
        return String(localized: resource)
    }

    @ViewBuilder
    private func editView(for item: PendingImport) -> some View {
        let targetAccountId = resolveAccountId(for: item)
        if let accountId = targetAccountId {
            let approver = PendingImportApprover(store: budgetStore)
            VStack(spacing: 0) {
                if let context = currencyContext(for: item) {
                    Text(context)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.orange.opacity(0.12))
                }
                AddTransactionView(
                    accountId: accountId,
                    payee: item.payee ?? "",
                    amountCents: item.amount.flatMap { Transaction.cents(fromDollars: $0) },
                    date: item.date,
                    notes: item.rawText,
                    categoryId: nil,
                    isIncome: item.isIncome,
                    cleared: false,
                    saveOverride: { form in
                        try await approver.saveEdited(item, form: form)
                    },
                    onSaved: { _ in
                        try store.remove(id: item.id)
                    },
                    reviewRequirement: reviewRequirement(for: item)
                )
                .environmentObject(budgetStore)
            }
        } else {
            ContentUnavailableView(
                "No Accounts",
                systemImage: "banknote",
                description: Text("Please add an account before editing this import.")
            )
        }
    }

    private func currencyContext(for item: PendingImport) -> String? {
        if let originBudgetId = item.originBudgetId,
           originBudgetId != budgetStore.currentBudgetId {
            return String(localized: "This import belongs to a different budget. Review and confirm adoption into the active budget before saving.")
        }
        guard let sourceCurrencyCode = item.sourceCurrencyCode else {
            if item.originBudgetId == nil {
                return String(localized: "This older import has no budget identity. Review and save it to adopt it into the active budget.")
            }
            return String(localized: "Currency was not identified. Active budget: \(PendingImport.normalizedCurrencyCode(budgetStore.currencyCode)). Review and confirm before saving.")
        }
        let source = PendingImport.normalizedCurrencyCode(sourceCurrencyCode)
        let budget = PendingImport.normalizedCurrencyCode(budgetStore.currencyCode)
        guard source != budget else { return nil }
        return String(localized: "Source currency: \(source). Active budget: \(budget). Review and confirm before saving.")
    }

    private func reviewRequirement(for item: PendingImport) -> PendingImportReviewRequirement? {
        if item.originBudgetId == nil || item.originBudgetId != budgetStore.currentBudgetId {
            return .adoptIntoActiveBudget
        }
        guard let source = item.sourceCurrencyCode else {
            return .confirmActiveBudgetCurrency(source: nil, budget: PendingImport.normalizedCurrencyCode(budgetStore.currencyCode))
        }
        let normalizedSource = PendingImport.normalizedCurrencyCode(source)
        let normalizedBudget = PendingImport.normalizedCurrencyCode(budgetStore.currencyCode)
        guard normalizedSource != normalizedBudget else { return nil }
        return .confirmActiveBudgetCurrency(source: normalizedSource, budget: normalizedBudget)
    }

    private func resolveAccountId(for item: PendingImport) -> String? {
        PendingImportApprover.resolveAccountId(
            cardHint: item.cardHint,
            accounts: budgetStore.accounts,
            cardMappings: budgetStore.cardAccountMappings,
            defaultAccountId: budgetStore.defaultAccountId
        )
    }

    /// Seed account for the edit form: strict hint resolution, then the default
    /// account, then any open account. The form has an account picker, so the
    /// fallbacks are a starting point the user can change — nothing is written
    /// silently, and nil only when there is truly no open account. This chain
    /// must be at least as permissive as `PendingImportApprover.approve`, whose
    /// `noAccountAvailable` recovery path sends the user here to pick one.
    nonisolated static func seedAccountId(
        cardHint: String?,
        accounts: [Account],
        cardMappings: [String: String],
        defaultAccountId: String?
    ) -> String? {
        PendingImportApprover.resolveAccountId(
            cardHint: cardHint,
            accounts: accounts,
            cardMappings: cardMappings,
            defaultAccountId: defaultAccountId
        )
    }
}

// MARK: - Row

private struct PendingImportRow: View {
    let item: PendingImport
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.payee ?? String(localized: "Unknown Payee"))
                    .font(.headline)
                Spacer()
                if let amount = item.amount {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(PendingImportsView.amountString(
                            amount,
                            isIncome: item.isIncome,
                            currencyCode: PendingImport.normalizedCurrencyCode(budgetStore.currencyCode),
                            sourceCurrencyCode: item.sourceCurrencyCode,
                            narrowSymbol: budgetStore.useNarrowCurrencySymbol,
                            locale: locale
                        ))
                        .font(.headline)
                        .foregroundStyle(item.isIncome ? .green : .primary)
                        if item.sourceCurrencyCode == nil {
                            Text("Currency unknown: \(PendingImport.normalizedCurrencyCode(budgetStore.currencyCode)) budget")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }

            HStack {
                if let hint = item.cardHint {
                    Text(String(format: String(localized: "Card ••%@"), hint))
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

}

extension PendingImportsView {
    nonisolated static func amountString(
        _ amount: Double,
        isIncome: Bool,
        currencyCode: String,
        sourceCurrencyCode: String?,
        narrowSymbol: Bool,
        locale: Locale
    ) -> String {
        guard let cents = Transaction.cents(fromDollars: amount) else { return "" }
        return CurrencyAmountFormat.string(
            cents: isIncome ? cents : -cents,
            currencyCode: PendingImport.normalizedCurrencyCode(sourceCurrencyCode ?? currencyCode),
            narrowSymbol: narrowSymbol,
            locale: locale
        )
    }
}
