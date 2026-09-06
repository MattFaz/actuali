import SwiftUI

enum TransactionBulkActionLocalization {
    nonisolated static func duplicateLabel(
        count: Int, locale: Locale, bundle: Bundle = .main
    ) -> String {
        String(localized: LocalizedStringResource(
            String.LocalizationValue("Duplicate \(count) selected transactions"),
            locale: locale, bundle: bundle))
    }

    nonisolated static func deleteLabel(
        count: Int, locale: Locale, bundle: Bundle = .main
    ) -> String {
        String(localized: LocalizedStringResource(
            String.LocalizationValue("Delete \(count) selected transactions"),
            locale: locale, bundle: bundle))
    }

    nonisolated static func deleteConfirmationTitle(
        count: Int, locale: Locale, bundle: Bundle = .main
    ) -> String {
        String(localized: LocalizedStringResource(
            String.LocalizationValue("Delete \(count) transactions?"),
            locale: locale, bundle: bundle))
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

    private var totalCount: Int { transactions.count }
    private var selectedCount: Int { selectedIds.count }
    private var allSelected: Bool {
        totalCount > 0 && selectedCount == totalCount
    }

    private var selectedTransactions: [Transaction] {
        transactions.filter { selectedIds.contains($0.id) }
    }

    var body: some View {
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
            } label: {
                Image(systemName: "checkmark.circle")
                    .font(.body.weight(.medium))
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel(ReportStrings.text("Set Cleared Status", locale: locale))
            .disabled(selectedCount == 0)

            Button {
                let selected = selectedTransactions
                Task {
                    await budgetStore.duplicateTransactions(selected)
                    selectedIds.removeAll()
                    withAnimation { isSelecting = false }
                }
            } label: {
                Label(selectedCount > 0 ? "(\(selectedCount))" : "", systemImage: "plus.square.on.square")
                    .font(.subheadline.weight(.semibold))
            }
                .accessibilityLabel(TransactionBulkActionLocalization.duplicateLabel(
                    count: selectedCount, locale: locale))
            .disabled(selectedCount == 0)

            Button(role: .destructive) {
                showingConfirmDelete = true
            } label: {
                Label(selectedCount > 0 ? "(\(selectedCount))" : "", systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
            }
                .accessibilityLabel(TransactionBulkActionLocalization.deleteLabel(
                    count: selectedCount, locale: locale))
            .disabled(selectedCount == 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(radius: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .onChange(of: transactions) {
            // Drop ids the list no longer holds (refilter, search, account
            // switch), so the counts match what the actions will touch.
            selectedIds.formIntersection(transactions.map(\.id))
        }
        .confirmationDialog(
            TransactionBulkActionLocalization.deleteConfirmationTitle(
                count: selectedCount, locale: locale),
            isPresented: $showingConfirmDelete,
            titleVisibility: .visible
        ) {
            Button(TransactionBulkActionLocalization.deleteConfirmationAction(
                count: selectedCount, locale: locale), role: .destructive) {
                let selected = selectedTransactions
                Task {
                    await budgetStore.deleteTransactions(selected)
                    selectedIds.removeAll()
                    withAnimation { isSelecting = false }
                }
            }
        }
    }
}
