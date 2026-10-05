import SwiftUI

enum TransactionBulkActionLocalization {
    nonisolated static func duplicateLabel(
        count: Int, locale: Locale, bundle: Bundle = .main
    ) -> String {
        String(localized: LocalizedStringResource(
            String.LocalizationValue("Duplicate \(count) selected transactions"),
            locale: locale, bundle: bundle
        ))
    }

    nonisolated static func deleteLabel(
        count: Int, locale: Locale, bundle: Bundle = .main
    ) -> String {
        String(localized: LocalizedStringResource(
            String.LocalizationValue("Delete \(count) selected transactions"),
            locale: locale, bundle: bundle
        ))
    }

    nonisolated static func deleteConfirmationTitle(
        count: Int, locale: Locale, bundle: Bundle = .main
    ) -> String {
        String(localized: LocalizedStringResource(
            String.LocalizationValue("Delete \(count) transactions?"),
            locale: locale, bundle: bundle
        ))
    }

    nonisolated static func deleteConfirmationAction(
        count: Int, locale: Locale, bundle: Bundle = .main
    ) -> String {
        deleteLabel(count: count, locale: locale, bundle: bundle)
    }
}

/// Pure rules behind the bar's batch edits and summary.
enum TransactionBulkEdit {
    /// The selection's net amount in cents (outflows negative).
    nonisolated static func total(of transactions: [Transaction]) -> Int {
        transactions.reduce(0) { $0 + $1.amount }
    }

    /// Whether two transactions can be merged, following Actual's rules
    /// (loot-core `validForMerge`): same account and amount. Transfers are
    /// left out for now.
    nonisolated static func canMerge(_ a: Transaction, _ b: Transaction) -> Bool {
        a.id != b.id
            && a.accountId == b.accountId
            && a.amount == b.amount
            && a.transferId == nil && a.transferAcct == nil
            && b.transferId == nil && b.transferAcct == nil
            && a.parentId == nil && b.parentId == nil
    }

    /// Which of two mergeable transactions survives, per Actual's
    /// `determineKeepDrop`: the bank-imported one, then the one with an
    /// imported payee, then the earlier one (the second on a tie).
    nonisolated static func keepAndDrop(
        _ a: Transaction, _ b: Transaction, importedIds: Set<String>
    ) -> (keep: Transaction, drop: Transaction) {
        let aImported = importedIds.contains(a.id)
        let bImported = importedIds.contains(b.id)
        if bImported, !aImported {
            return (b, a)
        }
        if aImported, !bImported {
            return (a, b)
        }
        let aPayee = !(a.importedPayee ?? "").isEmpty
        let bPayee = !(b.importedPayee ?? "").isEmpty
        if bPayee, !aPayee {
            return (b, a)
        }
        if aPayee, !bPayee {
            return (a, b)
        }
        return a.date < b.date ? (a, b) : (b, a)
    }

    /// The kept transaction after absorbing what the dropped one has and it
    /// lacks (payee, category, notes), with cleared, reconciled and schedule
    /// carried over if either had them. A split parent keeps no category.
    nonisolated static func merged(keep: Transaction, drop: Transaction) -> Transaction {
        var result = keep
        if keep.payeeId == nil {
            result.payeeId = drop.payeeId
            result.payeeName = drop.payeeName
        }
        if (keep.notes ?? "").isEmpty {
            result.notes = drop.notes
        }
        if keep.categoryId == nil, !keep.isParent {
            result.categoryId = drop.categoryId
            result.categoryName = drop.categoryName
        }
        result.cleared = keep.cleared || drop.cleared
        result.reconciled = keep.reconciled || drop.reconciled
        result.schedule = keep.schedule ?? drop.schedule
        return result
    }

    /// `notes` with `#tag` appended, or nil when the note already carries
    /// the tag (compared case-insensitively, like Actual's tag filter).
    nonisolated static func notes(adding tag: String, to notes: String?) -> String? {
        let name = Tag.normalizeTagName(tag)
        guard Tag.isValidTagName(name) else { return nil }
        let existing = (notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if TagFilter.notesContainTag(existing, tag: "#" + name, caseSensitive: false) {
            return nil
        }
        return existing.isEmpty ? "#" + name : existing + " #" + name
    }
}

struct TransactionBulkActionBar: View {
    let transactions: [Transaction]
    @Binding var selectedIds: Set<String>
    @Binding var isSelecting: Bool
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale

    @State private var showingConfirmDelete = false
    @State private var showingCategoryPicker = false
    @State private var showingTagPicker = false
    @State private var pickedCategoryId: String?

    private var totalCount: Int {
        transactions.count
    }

    private var selectedCount: Int {
        selectedIds.count
    }

    private var allSelected: Bool {
        totalCount > 0 && selectedCount == totalCount
    }

    private var selectedTransactions: [Transaction] {
        transactions.filter { selectedIds.contains($0.id) }
    }

    /// More than one selected: the bar grows into a card with the count and
    /// the selection's total above the actions.
    private var showsSummary: Bool {
        selectedCount > 1
    }

    /// Merge is offered for exactly two transactions that can be merged.
    private var canMergeSelection: Bool {
        guard selectedCount == 2 else { return false }
        let selected = selectedTransactions
        return selected.count == 2 && TransactionBulkEdit.canMerge(selected[0], selected[1])
    }

    var body: some View {
        VStack(spacing: 10) {
            if showsSummary {
                summaryRow
                Divider()
            }
            actionRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(radius: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .animation(.snappy(duration: 0.25), value: showsSummary)
        .onChange(of: transactions) {
            // Drop ids the list no longer holds (refilter, search, account
            // switch), so the counts match what the actions will touch.
            selectedIds.formIntersection(transactions.map(\.id))
        }
        .sheet(isPresented: $showingCategoryPicker) {
            NavigationStack {
                CategoryPickerView(selectedCategoryId: $pickedCategoryId) {
                    let selected = selectedTransactions
                    let categoryId = pickedCategoryId
                    Task { await budgetStore.setCategory(categoryId, for: selected) }
                }
            }
        }
        .sheet(isPresented: $showingTagPicker) {
            TransactionTagPickerSheet { tag in
                let selected = selectedTransactions
                Task { await budgetStore.addTag(tag, to: selected) }
            }
        }
        .confirmationDialog(
            TransactionBulkActionLocalization.deleteConfirmationTitle(
                count: selectedCount, locale: locale
            ),
            isPresented: $showingConfirmDelete,
            titleVisibility: .visible
        ) {
            Button(TransactionBulkActionLocalization.deleteConfirmationAction(
                count: selectedCount, locale: locale
            ), role: .destructive) {
                let selected = selectedTransactions
                Task {
                    await budgetStore.deleteTransactions(selected)
                    selectedIds.removeAll()
                    withAnimation { isSelecting = false }
                }
            }
        }
    }

    private var summaryRow: some View {
        let total = TransactionBulkEdit.total(of: selectedTransactions)
        return HStack(alignment: .firstTextBaseline) {
            Text("\(selectedCount) selected")
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 12)
            Text("Total")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(budgetStore.displayBalance(total))
                .font(.headline.monospacedDigit())
                .foregroundStyle(total < 0 ? Color.primary : Color.green)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transactionBulkBar.summary")
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button(ReportStrings.text(allSelected ? "Deselect All" : "Select All", locale: locale)) {
                if allSelected {
                    selectedIds.removeAll()
                } else {
                    selectedIds = Set(transactions.map(\.id))
                }
            }
            .font(.subheadline.weight(.semibold))

            Spacer()

            Button {
                pickedCategoryId = nil
                showingCategoryPicker = true
            } label: {
                iconLabel("tag")
            }
            .accessibilityLabel(ReportStrings.text("Categorize", locale: locale))
            .accessibilityIdentifier("transactionBulkBar.categorize")
            .disabled(selectedCount == 0)

            Button {
                showingTagPicker = true
            } label: {
                iconLabel("number")
            }
            .accessibilityLabel(ReportStrings.text("Add Tag", locale: locale))
            .accessibilityIdentifier("transactionBulkBar.tag")
            .disabled(selectedCount == 0)

            if canMergeSelection {
                Button {
                    let selected = selectedTransactions
                    Task {
                        await budgetStore.mergeTransactions(selected[0], selected[1])
                        selectedIds.removeAll()
                    }
                } label: {
                    iconLabel("arrow.triangle.merge")
                }
                .accessibilityLabel(ReportStrings.text("Merge", locale: locale))
                .accessibilityIdentifier("transactionBulkBar.merge")
            }

            Menu {
                Button {
                    let selected = selectedTransactions
                    Task {
                        await budgetStore.setClearedStatus(transactions: selected, cleared: true)
                    }
                } label: {
                    Label(ReportStrings.text("Mark Cleared", locale: locale), systemImage: "checkmark.circle")
                }
                Button {
                    let selected = selectedTransactions
                    Task {
                        await budgetStore.setClearedStatus(transactions: selected, cleared: false)
                    }
                } label: {
                    Label(ReportStrings.text("Mark Uncleared", locale: locale), systemImage: "circle")
                }
                Button {
                    let selected = selectedTransactions
                    Task {
                        await budgetStore.duplicateTransactions(selected)
                        selectedIds.removeAll()
                        withAnimation { isSelecting = false }
                    }
                } label: {
                    Label(ReportStrings.text("Duplicate", locale: locale), systemImage: "plus.square.on.square")
                }
                .accessibilityLabel(TransactionBulkActionLocalization.duplicateLabel(
                    count: selectedCount, locale: locale
                ))
            } label: {
                iconLabel("ellipsis.circle")
            }
            .accessibilityLabel(ReportStrings.text("More", locale: locale))
            .accessibilityIdentifier("transactionBulkBar.more")
            .disabled(selectedCount == 0)

            Button(role: .destructive) {
                showingConfirmDelete = true
            } label: {
                iconLabel("trash")
            }
            .accessibilityLabel(TransactionBulkActionLocalization.deleteLabel(
                count: selectedCount, locale: locale
            ))
            .disabled(selectedCount == 0)
        }
    }

    private func iconLabel(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.body.weight(.medium))
            .frame(width: 34, height: 32)
    }
}
