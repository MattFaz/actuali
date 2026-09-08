import SwiftUI

/// Sheet showing pending transaction imports queued from shared messages.
/// Users can approve (logs to budget), edit (opens add-transaction form),
/// or dismiss each import.
struct PendingImportsView: View {
    enum BulkApprovalFailureDisposition: Equatable {
        case removePendingImport
        case review
        case failure
    }

    enum BulkApprovalOutcome: Equatable {
        case none
        case review(deferredFailureCount: Int)
        case failure(count: Int)
    }

    @EnvironmentObject private var budgetStore: BudgetStore
    @ObservedObject private var store = PendingImportStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var editingItem: PendingImport?
    @State private var errorMessage: String?
    @State private var deferredFailureCount: Int?
    @State private var isProcessing = false

    var body: some View {
        NavigationStack {
            Group {
                let visibleImports = store.visibleImports()
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
            .sheet(item: $editingItem, onDismiss: presentDeferredFailure) { item in
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
        isProcessing = true
        let approver = PendingImportApprover(store: budgetStore)
        Task {
            do {
                _ = try await approver.approve(item)
                await MainActor.run {
                    defer { isProcessing = false }
                    do { try store.remove(id: item.id) } catch {
                        editingItem = nil
                        deferredFailureCount = nil
                        errorMessage = error.localizedDescription
                    }
                }
            } catch PendingImportApprover.ApproveError.noAccountAvailable {
                // Can't confidently pick an account (no card match, no default).
                // Send the user to the review form to choose one rather than
                // dead-ending on an error — same destination as tapping the row.
                await MainActor.run {
                    isProcessing = false
                    errorMessage = nil
                    editingItem = item
                }
            } catch PendingImportApprover.ApproveError.budgetIdentityRequired {
                await MainActor.run {
                    isProcessing = false
                    errorMessage = nil
                    editingItem = item
                }
            } catch PendingImportApprover.ApproveError.budgetMismatch {
                await MainActor.run {
                    isProcessing = false
                    errorMessage = nil
                    editingItem = item
                }
            } catch PendingImportApprover.ApproveError.sourceCurrencyRequired {
                await MainActor.run {
                    isProcessing = false
                    errorMessage = nil
                    editingItem = item
                }
            } catch PendingImportApprover.ApproveError.sourceCurrencyMismatch {
                await MainActor.run {
                    isProcessing = false
                    errorMessage = nil
                    editingItem = item
                }
            } catch PendingImportApprover.ApproveError.alreadyApproved {
                await MainActor.run {
                    defer { isProcessing = false }
                    do { try store.remove(id: item.id) } catch {
                        editingItem = nil
                        deferredFailureCount = nil
                        errorMessage = error.localizedDescription
                    }
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    editingItem = nil
                    deferredFailureCount = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func approveAll() {
        let approver = PendingImportApprover(store: budgetStore)
        let items = store.visibleImports()
        deferredFailureCount = nil
        errorMessage = nil
        isProcessing = true

        Task {
            var failedCount = 0
            var reviewItem: PendingImport?
            for item in items {
                do {
                    _ = try await approver.approve(item)
                    do { try await MainActor.run { try store.remove(id: item.id) } }
                    catch { failedCount += 1 }
                } catch {
                    switch Self.bulkApprovalDisposition(for: error) {
                    case .removePendingImport:
                        do {
                            try await MainActor.run { try store.remove(id: item.id) }
                        } catch {
                            failedCount += 1
                        }
                    case .review:
                        reviewItem = reviewItem ?? item
                    case .failure:
                        failedCount += 1
                    }
                }
            }
            await MainActor.run {
                isProcessing = false
                switch Self.bulkApprovalOutcome(reviewItem: reviewItem, failedCount: failedCount) {
                case .none:
                    break
                case .review(let deferredFailureCount):
                    errorMessage = nil
                    self.deferredFailureCount = deferredFailureCount > 0 ? deferredFailureCount : nil
                    editingItem = reviewItem
                case .failure(let count):
                    editingItem = nil
                    deferredFailureCount = nil
                    errorMessage = Self.approvalFailureMessage(count: count)
                }
            }
        }
    }

    private func presentDeferredFailure() {
        guard let count = deferredFailureCount else { return }
        deferredFailureCount = nil
        editingItem = nil
        errorMessage = Self.approvalFailureMessage(count: count)
    }

    nonisolated static func bulkApprovalDisposition(
        for error: any Error
    ) -> BulkApprovalFailureDisposition {
        guard let error = error as? PendingImportApprover.ApproveError else {
            return .failure
        }
        switch error {
        case .alreadyApproved:
            return .removePendingImport
        case .noAccountAvailable, .accountClosed, .budgetMismatch,
             .budgetIdentityRequired, .sourceCurrencyRequired,
             .sourceCurrencyMismatch, .reviewConfirmationRequired:
            return .review
        case .invalidAmount, .suppressedByRule, .writeFailed:
            return .failure
        }
    }

    nonisolated static func bulkApprovalOutcome(
        reviewItem: PendingImport?,
        failedCount: Int
    ) -> BulkApprovalOutcome {
        if reviewItem != nil {
            return .review(deferredFailureCount: failedCount)
        }
        return failedCount > 0 ? .failure(count: failedCount) : .none
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
                    reviewRequirements: item.reviewRequirements(
                        activeBudgetId: budgetStore.currentBudgetId,
                        budgetCurrency: budgetStore.currencyCode
                    )
                )
                .environmentObject(budgetStore)
            }
        } else {
            ContentUnavailableView(
                "No Accounts",
                systemImage: "building.columns",
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

    private func resolveAccountId(for item: PendingImport) -> String? {
        PendingImportApprover.seedAccountId(
            cardHint: item.cardHint,
            accounts: budgetStore.accounts,
            cardMappings: budgetStore.cardAccountMappings,
            defaultAccountId: budgetStore.defaultAccountId
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
                            numberFormat: budgetStore.numberFormat,
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
        numberFormat: ActualNumberFormat,
        locale: Locale
    ) -> String {
        guard let cents = Transaction.cents(fromDollars: amount) else { return "" }
        return CurrencyAmountFormat.string(
            cents: isIncome ? cents : -cents,
            currencyCode: PendingImport.normalizedCurrencyCode(sourceCurrencyCode ?? currencyCode),
            narrowSymbol: narrowSymbol,
            numberFormat: numberFormat,
            locale: locale
        )
    }
}
