import SwiftUI

/// Sheet showing pending transaction imports queued from shared messages,
/// and below them what this device's bank sync imported since it was last open.
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
    @Environment(\.locale) private var locale

    @State private var editingItem: PendingImport?
    @State private var errorMessage: String?
    @State private var deferredFailureCount: Int?
    @State private var isProcessing = false
    /// What this device's bank sync imported and nobody has looked at yet.
    /// Already in the budget, so there is nothing to approve: seeing them
    /// here is the review, and leaving clears the marks.
    @State private var newTransactions: [Transaction] = []
    @State private var editingTransaction: Transaction?

    var body: some View {
        NavigationStack {
            Group {
                let visibleImports = store.visibleImports()
                let staged = budgetStore.stagedBankTransactions
                if visibleImports.isEmpty, staged.isEmpty, budgetStore.unreviewedTransactions.isEmpty {
                    ContentUnavailableView(
                        "No Pending Imports",
                        systemImage: "tray",
                        description: Text("Share a bank message to Actuali to import transactions")
                    )
                } else {
                    List {
                        Section {
                            ForEach(visibleImports) { item in
                                Button {
                                    editingItem = item
                                } label: {
                                    PendingImportRow(item: item)
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        do { try store.remove(id: item.id) } catch {
                                            errorMessage = PendingImportApprover.localizedErrorMessage(
                                                for: error, locale: locale
                                            )
                                        }
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
                            // Held back by "Approve Before Importing": not in
                            // the budget until approved here.
                            ForEach(staged) { item in
                                StagedBankTransactionRow(item: item)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            budgetStore.rejectStagedBankTransactions([item])
                                        } label: {
                                            Label(String(localized: "Reject"), systemImage: "xmark")
                                        }
                                    }
                                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                        Button {
                                            approveStaged([item])
                                        } label: {
                                            Label("Approve", systemImage: "checkmark")
                                        }
                                        .tint(.green)
                                    }
                                    // The swipes are quick but hidden; a long press shows both.
                                    .contextMenu {
                                        Button {
                                            approveStaged([item])
                                        } label: {
                                            Label("Approve", systemImage: "checkmark")
                                        }
                                        Button(role: .destructive) {
                                            budgetStore.rejectStagedBankTransactions([item])
                                        } label: {
                                            Label(String(localized: "Reject"), systemImage: "xmark")
                                        }
                                    }
                                    .accessibilityIdentifier("review.staged.\(item.importedId)")
                            }
                        } header: {
                            if !visibleImports.isEmpty || !staged.isEmpty {
                                HStack {
                                    Text(String(localized: "Waiting for Approval"))
                                    Spacer()
                                    // On the section's own line: as a row of its
                                    // own it read as part of the list below.
                                    if isProcessing {
                                        ProgressView()
                                    } else if visibleImports.count + staged.count > 1 {
                                        Button("Approve All") { approveAll() }
                                            .font(.subheadline.weight(.semibold))
                                            .textCase(nil)
                                            .accessibilityIdentifier("review.approveAll")
                                    }
                                }
                            }
                        } footer: {
                            if !visibleImports.isEmpty || !staged.isEmpty {
                                Text(String(localized: "Not in your budget yet."))
                            }
                        }

                        if !newTransactions.isEmpty {
                            Section {
                                ForEach(newTransactions) { transaction in
                                    TransactionListRow(
                                        transaction: transaction,
                                        // No bulk actions here, so a long press selects nothing.
                                        isSelectionMode: .constant(false),
                                        editing: $editingTransaction
                                    )
                                }
                            } header: {
                                Text(String(localized: "Recently Imported"))
                            } footer: {
                                Text(String(localized: "Already in your budget."))
                            }
                            .accessibilityIdentifier("pendingImports.newTransactions")
                        }
                    }
                }
            }
            // Not "Pending Imports": what a bank sync brought in is listed here too.
            .navigationTitle(String(localized: "Review"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Import Failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: {
                    if !$0 {
                        errorMessage = nil
                    }
                }
            )) {
                Button("OK") {}
            } message: {
                if let errorMessage {
                    Text(errorMessage)
                }
            }
            .sheet(item: $editingItem, onDismiss: presentDeferredFailure) { item in
                NavigationStack {
                    PendingImportEditView(item: item)
                        .environmentObject(budgetStore)
                }
            }
            .sheet(item: $editingTransaction) { transaction in
                AddTransactionView(editing: transaction)
                    .environmentObject(budgetStore)
            }
            // An edit or delete bumps dataVersion, which is what re-reads the rows.
            .task(id: budgetStore.dataVersion) {
                newTransactions = await budgetStore.fetchUnreviewedTransactions()
            }
            .onDisappear { budgetStore.markAllReviewed() }
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
                        errorMessage = PendingImportApprover.localizedErrorMessage(
                            for: error, locale: locale
                        )
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
                        errorMessage = PendingImportApprover.localizedErrorMessage(
                            for: error, locale: locale
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    editingItem = nil
                    deferredFailureCount = nil
                    errorMessage = PendingImportApprover.localizedErrorMessage(
                        for: error, locale: locale
                    )
                }
            }
        }
    }

    private func approveStaged(_ items: [StagedBankTransaction]) {
        guard !isProcessing else { return }
        isProcessing = true
        Task {
            defer { isProcessing = false }
            do {
                try await budgetStore.approveStagedBankTransactions(items)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func approveAll() {
        let approver = PendingImportApprover(store: budgetStore)
        let items = store.visibleImports()
        let staged = budgetStore.stagedBankTransactions
        deferredFailureCount = nil
        errorMessage = nil
        isProcessing = true

        Task {
            var failedCount = 0
            var reviewItem: PendingImport?
            do {
                try await budgetStore.approveStagedBankTransactions(staged)
            } catch {
                failedCount += budgetStore.stagedBankTransactions.count
            }
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
                    errorMessage = Self.approvalFailureMessage(count: count, locale: locale)
                }
            }
        }
    }

    private func presentDeferredFailure() {
        guard let count = deferredFailureCount else { return }
        deferredFailureCount = nil
        editingItem = nil
        errorMessage = Self.approvalFailureMessage(count: count, locale: locale)
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
        case .invalidAmount, .suppressedByRule, .noBudgetLoaded,
             .transactionNeedsRecovery, .writeFailed:
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

    /// Whether the banner should link to Currency Settings: only when its
    /// message is about the budget's currency, which an adoption prompt or a
    /// legacy import's message isn't.
    nonisolated static func offersCurrencySettings(
        for item: PendingImport,
        activeBudgetId: String?,
        budgetCurrency: String
    ) -> Bool {
        if let originBudgetId = item.originBudgetId, originBudgetId != activeBudgetId {
            return false
        }
        let budget = PendingImport.normalizedCurrencyCode(budgetCurrency)
        guard let source = item.sourceCurrencyCode else {
            return item.originBudgetId != nil && budget.isEmpty
        }
        return PendingImport.normalizedCurrencyCode(source) != budget
    }

    nonisolated static func currencyContext(
        for item: PendingImport,
        activeBudgetId: String?,
        budgetCurrency: String,
        locale: Locale,
        bundle: Bundle = .main
    ) -> String? {
        if let originBudgetId = item.originBudgetId,
           originBudgetId != activeBudgetId {
            return ReportStrings.text(
                "This import belongs to a different budget. Review and confirm adoption into the active budget before saving.",
                locale: locale,
                bundle: bundle
            )
        }
        guard let sourceCurrencyCode = item.sourceCurrencyCode else {
            if item.originBudgetId == nil {
                return ReportStrings.text(
                    "This older import has no budget identity. Review and save it to adopt it into the active budget.",
                    locale: locale,
                    bundle: bundle
                )
            }
            let budget = PendingImport.normalizedCurrencyCode(budgetCurrency)
            let budgetLabel = PendingImport.currencyLabel(budget, locale: locale, bundle: bundle)
            return ReportStrings.format(
                "Currency was not identified. Active budget: %@. Review and confirm before saving.",
                budgetLabel,
                locale: locale,
                bundle: bundle
            )
        }
        let source = PendingImport.normalizedCurrencyCode(sourceCurrencyCode)
        let budget = PendingImport.normalizedCurrencyCode(budgetCurrency)
        guard source != budget else { return nil }
        if budget.isEmpty {
            return ReportStrings.format(
                "This import is in %@, but the active budget has no currency set. No currency conversion will be performed.",
                source,
                locale: locale,
                bundle: bundle
            )
        }
        return ReportStrings.format(
            "This import is in %@, but the active budget uses %@. No currency conversion will be performed.",
            source,
            budget,
            locale: locale,
            bundle: bundle
        )
    }
}

// MARK: - Edit View

private struct PendingImportEditView: View {
    let item: PendingImport
    @EnvironmentObject private var budgetStore: BudgetStore
    @ObservedObject private var store = PendingImportStore.shared
    @Environment(\.locale) private var locale
    @State private var mappingDraft: CardMappingDraft?

    private var targetAccountId: String? {
        PendingImportApprover.seedAccountId(
            cardHint: item.cardHint,
            accounts: budgetStore.accounts,
            cardMappings: budgetStore.cardAccountMappings,
            defaultAccountId: budgetStore.defaultAccountId
        )
    }

    var body: some View {
        if let accountId = targetAccountId {
            let approver = PendingImportApprover(store: budgetStore)
            VStack(spacing: 0) {
                if let context = PendingImportsView.currencyContext(
                    for: item,
                    activeBudgetId: budgetStore.currentBudgetId,
                    budgetCurrency: budgetStore.currencyCode,
                    locale: locale
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(context)
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if PendingImportsView.offersCurrencySettings(
                            for: item,
                            activeBudgetId: budgetStore.currentBudgetId,
                            budgetCurrency: budgetStore.currencyCode
                        ) {
                            NavigationLink {
                                DisplaySettingsView()
                            } label: {
                                Label(String(localized: "Currency Settings"), systemImage: "gearshape")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .accessibilityIdentifier("pendingImport.currencySettings")
                        }
                    }
                    .padding()
                    .background(.orange.opacity(0.12))
                }

                if let cardHint = item.cardHint,
                   PendingImportsView.isCardUnmapped(
                       hint: cardHint,
                       originBudgetId: item.originBudgetId,
                       activeBudgetId: budgetStore.currentBudgetId,
                       accounts: budgetStore.accounts,
                       cardMappings: budgetStore.cardAccountMappings
                   ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(PendingImportsView.cardUnmappedContext(hint: cardHint, locale: locale))
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            mappingDraft = PendingImportsView.mappingDraft(hint: cardHint, accountId: accountId)
                        } label: {
                            Label(String(localized: "Map Card"), systemImage: "creditcard")
                                .font(.subheadline.weight(.semibold))
                        }
                        .accessibilityIdentifier("pendingImport.mapCard")
                    }
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
            .sheet(item: $mappingDraft) { draft in
                CardMappingEditor(draft: draft)
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
}

// MARK: - Row

/// A bank transaction waiting for approval: what the bank sent, and the
/// account it would land in.
private struct StagedBankTransactionRow: View {
    let item: StagedBankTransaction
    @EnvironmentObject private var budgetStore: BudgetStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.payeeName)
                    .font(.headline)
                Spacer()
                Text(budgetStore.formatCurrency(item.amount))
                    .font(.headline)
                    .foregroundStyle(item.amount > 0 ? .green : .primary)
            }
            HStack {
                Label(
                    budgetStore.accounts.first { $0.id == item.accountId }?.name ?? String(localized: "Bank Sync"),
                    systemImage: "building.columns"
                )
                Spacer()
                Text(Transaction.formattedDate(from: item.date))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct PendingImportRow: View {
    let item: PendingImport
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.payee ?? PendingImportsView.unknownPayee(locale: locale))
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
                    HStack(spacing: 4) {
                        Text(PendingImportsView.cardLabel(hint, locale: locale))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if PendingImportsView.isCardUnmapped(
                            hint: hint,
                            originBudgetId: item.originBudgetId,
                            activeBudgetId: budgetStore.currentBudgetId,
                            accounts: budgetStore.accounts,
                            cardMappings: budgetStore.cardAccountMappings
                        ) {
                            Text(String(localized: "Unmapped"))
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .accessibilityIdentifier("pendingImport.unmappedCard")
                        }
                    }
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
    nonisolated static func unknownPayee(locale: Locale, bundle: Bundle = .main) -> String {
        ReportStrings.text("Unknown Payee", locale: locale, bundle: bundle)
    }

    nonisolated static func cardLabel(
        _ hint: String,
        locale: Locale,
        bundle: Bundle = .main
    ) -> String {
        ReportStrings.format("Card ••%@", hint, locale: locale, bundle: bundle)
    }

    nonisolated static func isCardUnmapped(
        hint: String?,
        originBudgetId: String?,
        activeBudgetId: String?,
        accounts: [Account],
        cardMappings: [String: String]
    ) -> Bool {
        guard originBudgetId == nil || originBudgetId == activeBudgetId,
              let hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty
        else { return false }
        return BudgetStore.resolveAccountId(hint: hint, accounts: accounts, cardMappings: cardMappings) == nil
    }

    nonisolated static func mappingDraft(hint: String, accountId: String) -> CardMappingDraft {
        CardMappingDraft(
            accountId: accountId,
            keywords: [hint.trimmingCharacters(in: .whitespacesAndNewlines)],
            originalKeywords: []
        )
    }

    nonisolated static func cardUnmappedContext(
        hint: String,
        locale: Locale,
        bundle: Bundle = .main
    ) -> String {
        let label = cardLabel(hint, locale: locale, bundle: bundle)
        return ReportStrings.format(
            "%@ is not mapped to an account. Map it to route future imports automatically.",
            label,
            locale: locale,
            bundle: bundle
        )
    }

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
