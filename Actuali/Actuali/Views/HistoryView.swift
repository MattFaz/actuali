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
                    HStack(spacing: 12) {
                        Image(systemName: symbol(for: action.kind))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 44)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(action.title)
                                    .font(.caption)
                                    .foregroundStyle(action.status == .undone ? .secondary : .primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                if let amount = action.primarySnapshot?.amount {
                                    Text(budgetStore.formatCurrency(amount))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }

                            Text(detail(for: action))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .layoutPriority(1)

                        Spacer(minLength: 6)

                        if action.status == .undone {
                            Text(String(localized: "Undone"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .accessibilityLabel(String(localized: "Undone"))
                        } else if historyStore.canUndo(action) {
                            Button(String(localized: "Undo")) { selectedAction = action }
                                .font(.caption)
                                .frame(minWidth: 52, minHeight: 44, alignment: .trailing)
                                .contentShape(Rectangle())
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .frame(minHeight: 54)
                    .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
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
            set: {
                if !$0 {
                    historyStore.clearError()
                }
            }
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

        if action.kind == .edited {
            let primaryRootID = snapshot.parentId ?? snapshot.id
            for changedSnapshot in action.after {
                let changedRootID = changedSnapshot.parentId ?? changedSnapshot.id
                guard changedRootID == primaryRootID else { continue }
                guard let before = action.before.first(where: { $0.id == changedSnapshot.id }) else {
                    continue
                }

                if before.amount != changedSnapshot.amount {
                    return String(
                        format: String(localized: "Amount: %@ → %@"),
                        budgetStore.formatCurrency(before.amount),
                        budgetStore.formatCurrency(changedSnapshot.amount)
                    )
                }
                if before.categoryId != changedSnapshot.categoryId {
                    return String(
                        format: String(localized: "Category: %@ → %@"),
                        before.categoryName ?? String(localized: "Uncategorized"),
                        changedSnapshot.categoryName ?? String(localized: "Uncategorized")
                    )
                }
                if before.payeeId != changedSnapshot.payeeId {
                    return String(
                        format: String(localized: "Payee: %@ → %@"),
                        before.payeeName ?? String(localized: "Transaction"),
                        changedSnapshot.payeeName ?? String(localized: "Transaction")
                    )
                }
                if before.notes != changedSnapshot.notes {
                    if before.notes?.isEmpty == false, changedSnapshot.notes?.isEmpty == false {
                        return String(localized: "Note changed")
                    }
                    if changedSnapshot.notes?.isEmpty == false {
                        return String(localized: "Note added")
                    }
                    return String(localized: "Note removed")
                }
                if before.date != changedSnapshot.date {
                    return String(localized: "Date changed")
                        + ": "
                        + Transaction.formattedDate(from: before.date)
                        + " → "
                        + Transaction.formattedDate(from: changedSnapshot.date)
                }
                if before.cleared != changedSnapshot.cleared {
                    return changedSnapshot.cleared
                        ? String(localized: "Marked cleared")
                        : String(localized: "Marked uncleared")
                }
                if before.reconciled != changedSnapshot.reconciled {
                    return changedSnapshot.reconciled
                        ? String(localized: "Marked reconciled")
                        : String(localized: "Marked unreconciled")
                }
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
        if let category {
            parts.append(category)
        }
        if let account {
            parts.append(account)
        }
        if hasNotes {
            parts.append(String(localized: "Note"))
        }
        return parts.isEmpty ? action.detail : parts.joined(separator: " · ")
    }

    private func symbol(for kind: HistoryActionKind) -> String {
        switch kind {
        case .created: "plus.circle"
        case .edited: "pencil.circle"
        case .deleted: "trash.circle"
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
                    }

                    let snapshots = action.before.isEmpty ? action.after : action.before
                    ForEach(snapshots) { snapshot in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(
                                snapshot.payeeName?.isEmpty == false
                                    ? snapshot.payeeName!
                                    : String(localized: "Transaction")
                            )
                            Text(Transaction.formattedDate(from: snapshot.date))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(formatAmount(snapshot.amount))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
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
