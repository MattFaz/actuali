import Foundation
import Combine

extension Transaction {
    /// Compares only stable transaction state returned by the normal fetch path.
    /// Display-only values, insert-only values that aren't read back, and
    /// `sortOrder` normalization must not make a live row differ from history.
    func matchesLiveTransaction(_ transaction: Transaction) -> Bool {
        id == transaction.id &&
        accountId == transaction.accountId &&
        date == transaction.date &&
        amount == transaction.amount &&
        payeeId == transaction.payeeId &&
        categoryId == transaction.categoryId &&
        notes == transaction.notes &&
        cleared == transaction.cleared &&
        reconciled == transaction.reconciled &&
        transferId == transaction.transferId &&
        isParent == transaction.isParent &&
        parentId == transaction.parentId &&
        tombstone == transaction.tombstone &&
        importedPayee == transaction.importedPayee &&
        schedule == transaction.schedule
    }
}

enum HistoryActionKind: String, Codable {
    case created
    case edited
    case deleted
}

enum HistoryActionStatus: String, Codable {
    case applied
    case undone
}

struct HistoryAction: Identifiable, Codable, Equatable {
    let id: String
    let createdAt: Date
    let budgetID: String
    let kind: HistoryActionKind
    let before: [Transaction]
    let after: [Transaction]
    var status: HistoryActionStatus

    var primarySnapshot: Transaction? {
        after.first(where: { $0.parentId == nil }) ?? after.first ?? before.first
    }

    var title: String {
        if after.count == 2, after.allSatisfy({ $0.transferId != nil }) {
            switch kind {
            case .created: return String(localized: "Created transfer")
            case .edited: return String(localized: "Edited transfer")
            case .deleted: return String(localized: "Deleted transfer")
            }
        }
        if after.contains(where: { $0.isParent }) || before.contains(where: { $0.isParent }) {
            switch kind {
            case .created: return String(localized: "Added split transaction")
            case .edited: return String(localized: "Edited split transaction")
            case .deleted: return String(localized: "Deleted split transaction")
            }
        }
        let name = primarySnapshot?.payeeName.flatMap { $0.isEmpty ? nil : $0 }
            ?? String(localized: "Transaction")
        switch kind {
        case .created: return String(format: String(localized: "Added %@"), name)
        case .edited: return String(format: String(localized: "Edited %@"), name)
        case .deleted: return String(format: String(localized: "Deleted %@"), name)
        }
    }

    var detail: String {
        primarySnapshot.map { Transaction.formattedDate(from: $0.date) } ?? ""
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static var recordingSuppressed = false

    struct PendingUndo {
        let budgetID: String
        let expected: [Transaction]
        let removedIDs: Set<String>
    }

    static var pendingUndo: PendingUndo?

    @Published private(set) var actions: [HistoryAction] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var errorTitle = String(localized: "Couldn't Undo")

    private let defaults: UserDefaults
    private var loadedBudgetID: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(budgetID: String) {
        loadedBudgetID = budgetID
        guard let data = defaults.data(forKey: key(budgetID)) else {
            clearLoadedActions()
            loadedBudgetID = budgetID
            return
        }
        guard let decoded = try? JSONDecoder().decode([HistoryAction].self, from: data) else {
            actions = []
            errorTitle = String(localized: "Couldn't Load History")
            errorMessage = String(localized: "History couldn't be loaded. New history will continue from here.")
            return
        }
        errorMessage = nil
        errorTitle = String(localized: "Couldn't Undo")
        actions = decoded
            .filter { $0.budgetID == budgetID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func clearLoadedActions() {
        actions = []
        loadedBudgetID = nil
        errorMessage = nil
        errorTitle = String(localized: "Couldn't Undo")
    }

    func recordSnapshots(
        budgetID: String,
        kind: HistoryActionKind,
        before: [Transaction],
        after: [Transaction]
    ) {
        guard !Self.recordingSuppressed, !before.isEmpty || !after.isEmpty else { return }

        if loadedBudgetID != budgetID {
            load(budgetID: budgetID)
        }

        // ponytail: split edits currently publish parent/child changes separately;
        // only merge adjacent publications for the same parent within 0.5s. The
        // ceiling is intentional. A future operation-scoped History transaction
        // can remove the timing heuristic without changing stored transactions.
        if kind == .edited,
           let existing = actions.first,
           existing.status == .applied,
           existing.budgetID == budgetID,
           let existingParentID = Self.splitParentID(before: existing.before, after: existing.after),
           let parentID = Self.splitParentID(before: before, after: after),
           existingParentID == parentID,
           Date().timeIntervalSince(existing.createdAt) <= 0.5 {
            actions[0] = HistoryAction(
                id: existing.id,
                createdAt: existing.createdAt,
                budgetID: budgetID,
                kind: kind,
                before: Self.mergeBefore(existing.before, before),
                after: Self.mergeAfter(existing.after, after),
                status: .applied
            )
            save(budgetID)
            return
        }

        if let transaction = after.first,
           after.count == 1,
           let existing = actions.first,
           existing.status == .applied,
           existing.budgetID == budgetID,
           existing.kind == kind,
           existing.after.count == 1,
           let existingTransaction = existing.after.first,
           existingTransaction.id == transaction.transferId,
           existingTransaction.transferId == transaction.id {
            actions[0] = HistoryAction(
                id: existing.id,
                createdAt: existing.createdAt,
                budgetID: budgetID,
                kind: kind,
                before: existing.before + before,
                after: existing.after + after,
                status: .applied
            )
            save(budgetID)
            return
        }

        errorMessage = nil
        errorTitle = String(localized: "Couldn't Undo")
        actions.insert(
            HistoryAction(
                id: UUID().uuidString,
                createdAt: Date(),
                budgetID: budgetID,
                kind: kind,
                before: before,
                after: after,
                status: .applied
            ),
            at: 0
        )
        actions = Array(actions.prefix(10))
        save(budgetID)
    }

    func canUndo(_ action: HistoryAction) -> Bool {
        action.budgetID == loadedBudgetID &&
        action.status == .applied &&
        actions.first(where: { $0.status == .applied })?.id == action.id
    }

    func clearError() {
        errorMessage = nil
        errorTitle = String(localized: "Couldn't Undo")
    }

    func undo(_ action: HistoryAction, using budgetStore: BudgetStore) async {
        guard canUndo(action), action.budgetID == budgetStore.currentBudgetId else { return }
        errorMessage = nil
        errorTitle = String(localized: "Couldn't Undo")

        var live = Dictionary(uniqueKeysWithValues: budgetStore.transactions.map { ($0.id, $0) })
        let splitParentIDs = Set(
            action.before.compactMap { $0.isParent ? $0.id : $0.parentId } +
            action.after.compactMap { $0.isParent ? $0.id : $0.parentId }
        )
        for parentID in splitParentIDs {
            for child in await budgetStore.fetchSplitChildren(parentId: parentID) {
                live[child.id] = child
            }
        }

        let afterByID = Dictionary(uniqueKeysWithValues: action.after.map { ($0.id, $0) })
        for recordedAfter in action.after {
            if recordedAfter.tombstone {
                guard live[recordedAfter.id] == nil else {
                    errorMessage = String(localized: "This action changed after it was recorded, so it cannot be safely undone.")
                    return
                }
            } else {
                guard let actual = live[recordedAfter.id], recordedAfter.matchesLiveTransaction(actual) else {
                    errorMessage = String(localized: "This action changed after it was recorded, so it cannot be safely undone.")
                    return
                }
            }
        }

        for expected in action.before {
            guard let recordedAfter = afterByID[expected.id] else {
                guard live[expected.id] == nil else {
                    errorMessage = String(localized: "This action changed after it was recorded, so it cannot be safely undone.")
                    return
                }
                continue
            }

            if recordedAfter.tombstone {
                if live[expected.id] != nil {
                    errorMessage = String(localized: "This action changed after it was recorded, so it cannot be safely undone.")
                    return
                }
            } else if let actual = live[expected.id], !recordedAfter.matchesLiveTransaction(actual) {
                errorMessage = String(localized: "This action changed after it was recorded, so it cannot be safely undone.")
                return
            } else if live[expected.id] == nil {
                errorMessage = String(localized: "This action changed after it was recorded, so it cannot be safely undone.")
                return
            }
        }

        let expectedBefore: [Transaction]
        let removedIDs: Set<String>
        switch action.kind {
        case .created:
            expectedBefore = []
            removedIDs = Set(action.after.map(\.id))
        case .edited, .deleted:
            expectedBefore = action.before
            removedIDs = []
        }
        Self.pendingUndo = PendingUndo(
            budgetID: action.budgetID,
            expected: expectedBefore,
            removedIDs: removedIDs
        )
        Self.recordingSuppressed = true

        switch action.kind {
        case .created:
            budgetStore.error = nil
            await budgetStore.deleteTransactions(
                action.after.filter { $0.parentId == nil }
            )
            guard budgetStore.error == nil else {
                errorMessage = budgetStore.error
                Self.finishUndoRecording()
                return
            }
        case .edited, .deleted:
            let restorePairs = action.before.map { previous in
                (previous, afterByID[previous.id] ?? Self.tombstoned(previous))
            }
            // ponytail: restore one row per sync write so each update carries
            // only its own changed fields. Grouping rows would union their
            // field sets and can overwrite concurrent CRDT edits on untouched rows.
            var restoredPairs: [(Transaction, Transaction)] = []
            do {
                for (before, after) in restorePairs {
                    try await budgetStore.restoreTransaction(before, from: after)
                    restoredPairs.append((before, after))
                }
            } catch {
                // The restore calls are sequential today. Compensate on failure
                // so a multi-row Undo does not remain partially restored.
                do {
                    for (before, after) in restoredPairs.reversed() {
                        try await budgetStore.restoreTransaction(after, from: before)
                    }
                } catch {
                    errorMessage = String(localized: "Undo failed and the previous state could not be restored. Please reopen the budget and verify these transactions.")
                    Self.finishUndoRecording()
                    return
                }
                errorMessage = error.localizedDescription
                Self.finishUndoRecording()
                return
            }
        }

        guard let index = actions.firstIndex(where: { $0.id == action.id }) else {
            Self.finishUndoRecording()
            return
        }
        actions[index].status = .undone
        save(action.budgetID)
        Self.finishUndoRecording()
    }

    static func finishUndoRecording() {
        recordingSuppressed = false
        pendingUndo = nil
    }

    private func key(_ budgetID: String) -> String {
        "history.actions.\(budgetID)"
    }

    private func save(_ budgetID: String) {
        guard loadedBudgetID == budgetID else { return }
        guard let data = try? JSONEncoder().encode(actions) else { return }
        defaults.set(data, forKey: key(budgetID))
    }

    private static func tombstoned(_ transaction: Transaction) -> Transaction {
        var result = transaction
        result.tombstone = true
        return result
    }

    private static func splitParentID(
        before: [Transaction],
        after: [Transaction]
    ) -> String? {
        after.first(where: { $0.isParent })?.id
            ?? before.first(where: { $0.isParent })?.id
            ?? after.compactMap(\.parentId).first
            ?? before.compactMap(\.parentId).first
    }

    private static func mergeBefore(
        _ existing: [Transaction],
        _ newer: [Transaction]
    ) -> [Transaction] {
        var result = existing
        let existingIDs = Set(existing.map(\.id))
        result.append(contentsOf: newer.filter { !existingIDs.contains($0.id) })
        return result
    }

    private static func mergeAfter(
        _ existing: [Transaction],
        _ newer: [Transaction]
    ) -> [Transaction] {
        var result = existing
        for transaction in newer {
            if let index = result.firstIndex(where: { $0.id == transaction.id }) {
                result[index] = transaction
            } else {
                result.append(transaction)
            }
        }
        return result
    }
}
