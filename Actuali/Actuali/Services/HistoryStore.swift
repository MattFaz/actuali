import Foundation
import Combine

struct HistorySplitPortionSnapshot: Codable, Equatable {
    var categoryName: String?
    var amount: Int

    init(_ value: Transaction.SplitPortion) {
        categoryName = value.categoryName
        amount = value.amount
    }

    func value() -> Transaction.SplitPortion {
        Transaction.SplitPortion(categoryName: categoryName, amount: amount)
    }
}

struct HistoryTransactionSnapshot: Codable, Equatable, Identifiable {
    let id: String
    var accountId: String
    var date: Int
    var amount: Int
    var payeeId: String?
    var payeeName: String?
    var categoryId: String?
    var categoryName: String?
    var notes: String?
    var cleared: Bool
    var reconciled: Bool
    var transferId: String?
    var isParent: Bool
    var parentId: String?
    var tombstone: Bool
    var sortOrder: Double?
    var importedPayee: String?
    var schedule: String?
    var financialId: String?
    var startingBalanceFlag: Bool
    var transferAcct: String?
    var splitPortions: [HistorySplitPortionSnapshot]?

    init(_ tx: Transaction) {
        id = tx.id
        accountId = tx.accountId
        date = tx.date
        amount = tx.amount
        payeeId = tx.payeeId
        payeeName = tx.payeeName
        categoryId = tx.categoryId
        categoryName = tx.categoryName
        notes = tx.notes
        cleared = tx.cleared
        reconciled = tx.reconciled
        transferId = tx.transferId
        isParent = tx.isParent
        parentId = tx.parentId
        tombstone = tx.tombstone
        sortOrder = tx.sortOrder
        importedPayee = tx.importedPayee
        schedule = tx.schedule
        financialId = tx.financialId
        startingBalanceFlag = tx.startingBalanceFlag
        transferAcct = tx.transferAcct
        splitPortions = tx.splitPortions?.map(HistorySplitPortionSnapshot.init)
    }

    func transaction() -> Transaction {
        Transaction(
            id: id,
            accountId: accountId,
            date: date,
            amount: amount,
            payeeId: payeeId,
            payeeName: payeeName,
            categoryId: categoryId,
            categoryName: categoryName,
            notes: notes,
            cleared: cleared,
            reconciled: reconciled,
            transferId: transferId,
            isParent: isParent,
            parentId: parentId,
            tombstone: tombstone,
            sortOrder: sortOrder,
            importedPayee: importedPayee,
            schedule: schedule,
            financialId: financialId,
            startingBalanceFlag: startingBalanceFlag,
            transferAcct: transferAcct,
            splitPortions: splitPortions?.map { $0.value() }
        )
    }

    /// Compares the stable transaction state available from the normal fetch
    /// path. Display-only values, insert-only values that aren't read back,
    /// and `sortOrder` normalization must not make a live row look different
    /// from the snapshot that was recorded.
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
    let before: [HistoryTransactionSnapshot]
    let after: [HistoryTransactionSnapshot]
    var status: HistoryActionStatus

    var primarySnapshot: HistoryTransactionSnapshot? {
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
        let name = primarySnapshot?.payeeName.flatMap { $0.isEmpty ? nil : $0 } ?? "Transaction"
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
        let expected: [HistoryTransactionSnapshot]
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

    func record(
        budgetID: String,
        kind: HistoryActionKind,
        before: [Transaction],
        after: [Transaction]
    ) {
        recordSnapshots(
            budgetID: budgetID,
            kind: kind,
            before: before.map(HistoryTransactionSnapshot.init),
            after: after.map(HistoryTransactionSnapshot.init)
        )
    }

    func recordSnapshots(
        budgetID: String,
        kind: HistoryActionKind,
        before: [HistoryTransactionSnapshot],
        after: [HistoryTransactionSnapshot]
    ) {
        guard !Self.recordingSuppressed, !before.isEmpty || !after.isEmpty else { return }

        if loadedBudgetID != budgetID {
            load(budgetID: budgetID)
        }

        // ponytail: split edits currently publish parent/child changes separately;
        // only merge adjacent publications for the same parent within 0.5s. The
        // ceiling is intentional. A future operation-scoped History transaction
        // can remove the timing heuristic without changing stored snapshots.
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

        if let snapshot = after.first,
           after.count == 1,
           let existing = actions.first,
           existing.status == .applied,
           existing.budgetID == budgetID,
           existing.kind == kind,
           existing.after.count == 1,
           let existingSnapshot = existing.after.first,
           existingSnapshot.id == snapshot.transferId,
           existingSnapshot.transferId == snapshot.id {
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

        let expectedBefore: [HistoryTransactionSnapshot]
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
                action.after
                    .filter { $0.parentId == nil }
                    .map { $0.transaction() }
            )
            guard budgetStore.error == nil else {
                errorMessage = budgetStore.error
                Self.finishUndoRecording()
                return
            }
        case .edited, .deleted:
            let recordedAfterForRestore = action.before.map { previous in
                afterByID[previous.id] ?? Self.tombstoned(previous)
            }
            do {
                try await budgetStore.restoreTransactions(
                    action.before.map { $0.transaction() },
                    from: recordedAfterForRestore.map { $0.transaction() }
                )
            } catch {
                // The underlying batch API processes rows sequentially today.
                // Compensate on failure so a multi-row Undo does not remain
                // partially restored when one row fails.
                do {
                    try await budgetStore.restoreTransactions(
                        recordedAfterForRestore.map { $0.transaction() },
                        from: action.before.map { $0.transaction() }
                    )
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

    #if DEBUG
    func appendForTesting(_ action: HistoryAction, budgetID: String) {
        if loadedBudgetID != budgetID {
            load(budgetID: budgetID)
        }
        actions.insert(action, at: 0)
        actions = Array(actions.prefix(10))
        save(budgetID)
    }
    #endif

    private func key(_ budgetID: String) -> String {
        "history.actions.\(budgetID)"
    }

    private func save(_ budgetID: String) {
        guard loadedBudgetID == budgetID else { return }
        guard let data = try? JSONEncoder().encode(actions) else { return }
        defaults.set(data, forKey: key(budgetID))
    }

    private static func tombstoned(_ snapshot: HistoryTransactionSnapshot) -> HistoryTransactionSnapshot {
        var result = snapshot
        result.tombstone = true
        return result
    }

    private static func splitParentID(
        before: [HistoryTransactionSnapshot],
        after: [HistoryTransactionSnapshot]
    ) -> String? {
        after.first(where: { $0.isParent })?.id
            ?? before.first(where: { $0.isParent })?.id
            ?? after.compactMap(\.parentId).first
            ?? before.compactMap(\.parentId).first
    }

    private static func mergeBefore(
        _ existing: [HistoryTransactionSnapshot],
        _ newer: [HistoryTransactionSnapshot]
    ) -> [HistoryTransactionSnapshot] {
        var result = existing
        let existingIDs = Set(existing.map(\.id))
        result.append(contentsOf: newer.filter { !existingIDs.contains($0.id) })
        return result
    }

    private static func mergeAfter(
        _ existing: [HistoryTransactionSnapshot],
        _ newer: [HistoryTransactionSnapshot]
    ) -> [HistoryTransactionSnapshot] {
        var result = existing
        for snapshot in newer {
            if let index = result.firstIndex(where: { $0.id == snapshot.id }) {
                result[index] = snapshot
            } else {
                result.append(snapshot)
            }
        }
        return result
    }
}
