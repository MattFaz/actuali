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
