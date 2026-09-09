import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @StateObject private var historyStore = HistoryStore.shared
    @State private var selectedAction: HistoryAction?

    var body: some View {
        List {
            if historyStore.actions.isEmpty {
                ContentUnavailableView(
                    String(localized: "No History Yet"),
                    systemImage: "clock",
                    description: Text(String(localized: "Transaction changes appear here."))
                )
            } else {
                ForEach(historyStore.actions) { action in
                    HStack(spacing: 10) {
                        Image(systemName: symbol(for: action.kind))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(action.title)
                                    .font(.caption2)
                                    .foregroundStyle(action.status == .undone ? .secondary : .primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                if let amount = action.primarySnapshot?.amount {
                                    Text(budgetStore.formatCurrency(amount))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }

                            Text(detail(for: action))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .layoutPriority(1)

                        Spacer(minLength: 4)

                        if action.status == .undone {
                            Text(String(localized: "Undone"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .accessibilityLabel(String(localized: "Undone"))
                        } else if historyStore.canUndo(action) {
                            Button(String(localized: "Undo")) { selectedAction = action }
                                .font(.caption2)
                                .frame(minWidth: 44, alignment: .trailing)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .frame(height: 48)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowSeparator(.visible)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(String(localized: "History"))
        .task(id: budgetStore.currentBudgetId) { load() }
        .refreshable { load() }
        .sheet(item: $selectedAction) { action in
            HistoryUndoReviewView(
                action: action,
                detail: detail(for: action),
                formatAmount: { budgetStore.formatCurrency($0) }
            ) {
                Task {
                    await historyStore.undo(action, using: budgetStore)
                    if historyStore.errorMessage == nil {
                        selectedAction = nil
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .alert(historyStore.errorTitle, isPresented: Binding(
            get: { historyStore.errorMessage != nil },
            set: { if !$0 { historyStore.clearError() } }
        )) {
            Button("OK", role: .cancel) { historyStore.clearError() }
        } message: {
            Text(historyStore.errorMessage ?? "")
        }
    }

    private func load() {
        guard let budgetID = budgetStore.currentBudgetId else {
            historyStore.clearLoadedActions()
            return
        }
        historyStore.load(budgetID: budgetID)
    }

    private func detail(for action: HistoryAction) -> String {
        guard let snapshot = action.primarySnapshot else { return action.detail }

        let account = budgetStore.accounts.first(where: { $0.id == snapshot.accountId })?.name
        let category = snapshot.categoryName?.isEmpty == false ? snapshot.categoryName : nil
        let hasNotes = snapshot.notes?.isEmpty == false

        if action.kind == .edited,
           let before = action.before.first(where: { $0.id == snapshot.id }) {
            if before.amount != snapshot.amount {
                return String(
                    format: String(localized: "Amount: %@ → %@"),
                    budgetStore.formatCurrency(before.amount),
                    budgetStore.formatCurrency(snapshot.amount)
                )
            }
            if before.categoryName != snapshot.categoryName {
                return String(
                    format: String(localized: "Category: %@ → %@"),
                    before.categoryName ?? String(localized: "Uncategorized"),
                    snapshot.categoryName ?? String(localized: "Uncategorized")
                )
            }
            if before.payeeName != snapshot.payeeName {
                return String(
                    format: String(localized: "Payee: %@ → %@"),
                    before.payeeName ?? String(localized: "Transaction"),
                    snapshot.payeeName ?? String(localized: "Transaction")
                )
            }
            if before.notes != snapshot.notes {
                return before.notes?.isEmpty == false && hasNotes
                    ? String(localized: "Note changed")
                    : hasNotes ? String(localized: "Note added") : String(localized: "Note removed")
            }
            if before.date != snapshot.date {
                return String(localized: "Date changed")
            }
            if before.cleared != snapshot.cleared {
                return snapshot.cleared ? String(localized: "Marked cleared") : String(localized: "Marked uncleared")
            }
            if before.reconciled != snapshot.reconciled {
                return snapshot.reconciled ? String(localized: "Marked reconciled") : String(localized: "Marked unreconciled")
            }
        }

        if action.after.count == 2,
           let otherID = action.after.first(where: { $0.id != snapshot.id })?.accountId,
           let otherAccount = budgetStore.accounts.first(where: { $0.id == otherID })?.name {
            return String(
                format: String(localized: "%@ → %@"),
                account ?? String(localized: "Account"),
                otherAccount
            )
        }

        if snapshot.isParent, let portions = snapshot.splitPortions, !portions.isEmpty {
            return String(
                format: String(localized: "%@ categories · %@"),
                String(portions.count),
                account ?? String(localized: "Account")
            )
        }

        var parts: [String] = []
        if let category { parts.append(category) }
        if let account { parts.append(account) }
        if hasNotes { parts.append(String(localized: "Note")) }
        return parts.isEmpty ? action.detail : parts.joined(separator: " · ")
    }

    private func symbol(for kind: HistoryActionKind) -> String {
        switch kind {
        case .created: return "plus.circle"
        case .edited: return "pencil.circle"
        case .deleted: return "trash.circle"
        }
    }
}

private struct HistoryUndoReviewView: View {
    let action: HistoryAction
    let detail: String
    let formatAmount: (Int) -> String
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(action.title).font(.headline)
                    if let amount = action.primarySnapshot?.amount {
                        Text(formatAmount(amount)).font(.title3.monospacedDigit())
                    }
                    Text(detail).foregroundStyle(.secondary)
                }
                Section("Restore") {
                    if action.before.isEmpty {
                        Text(String(localized: "The transaction(s) created by this action will be removed."))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(action.before) { snapshot in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(snapshot.payeeName?.isEmpty == false ? snapshot.payeeName! : String(localized: "Transaction"))
                                Text(formatAmount(snapshot.amount))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "Review Undo"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Undo"), action: confirm).fontWeight(.semibold)
                }
            }
        }
    }
}
