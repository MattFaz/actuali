import Combine
import Foundation

@MainActor
final class HistoryObserver {
    private var cancellables = Set<AnyCancellable>()
    private var previousBudgetID: String?
    private var hasBaseline = false
    private var previous: [String: Transaction] = [:]
    private var previousSplitChildren: [String: [String: Transaction]] = [:]
    private var previousMessageID: Int64 = 0
    private var consumeTask: Task<Void, Never>?
    private var baselineGeneration = 0

    init(store: BudgetStore) {
        previousBudgetID = store.currentBudgetId

        store.$currentBudgetId
            .sink { [weak self, weak store] budgetID in
                guard let self, let store else { return }
                if budgetID != self.previousBudgetID {
                    self.previousBudgetID = budgetID
                    self.hasBaseline = false
                    self.previous = [:]
                    self.previousSplitChildren = [:]
                    self.baselineGeneration += 1
                    return
                }
                self.enqueueConsume(store: store, budgetID: budgetID, isRemote: store.isBankSyncing)
            }
            .store(in: &cancellables)

        store.$isLoading
            .sink { [weak self] loading in
                guard let self, Self.shouldResetBaselineForReload(isLoading: loading) else { return }
                self.hasBaseline = false
                self.previous = [:]
                self.previousSplitChildren = [:]
                self.baselineGeneration += 1
            }
            .store(in: &cancellables)

        // `transactions` is only the trigger. It holds just the newest page,
        // so `consume` diffs every live row from the database instead.
        store.$transactions
            .sink { [weak self, weak store] _ in
                guard let self, let store else { return }
                self.enqueueConsume(store: store, budgetID: store.currentBudgetId, isRemote: store.isBankSyncing)
            }
            .store(in: &cancellables)

        enqueueConsume(store: store, budgetID: store.currentBudgetId, isRemote: false)
    }

    static func shouldResetBaselineForReload(isLoading: Bool) -> Bool {
        isLoading
    }

    #if DEBUG
    /// Test-only: wait until every queued publication has been diffed.
    func drainForTesting() async {
        await consumeTask?.value
    }
    #endif

    private func enqueueConsume(store: BudgetStore, budgetID: String?, isRemote: Bool) {
        let generation = baselineGeneration
        let previousTask = consumeTask
        consumeTask = Task { @MainActor [weak self, weak store] in
            _ = await previousTask?.result
            guard let self, let store else { return }
            await self.consume(store, budgetID: budgetID, isRemote: isRemote, generation: generation)
        }
    }

    private func consume(
        _ store: BudgetStore,
        budgetID: String?,
        isRemote: Bool,
        generation: Int
    ) async {
        guard generation == baselineGeneration else { return }

        guard let budgetID else {
            hasBaseline = false
            previous = [:]
            previousSplitChildren = [:]
            return
        }

        guard budgetID == store.currentBudgetId else { return }

        // ponytail: reads every live row on each publication. Fine for
        // personal budgets; recording at the write call sites removes the
        // read if huge budgets make it slow.
        guard let snapshot = try? await store.fetchAllLiveTransactions(
            remoteChangesAfter: hasBaseline ? previousMessageID : nil
        ) else { return }
        guard generation == baselineGeneration else { return }
        guard budgetID == store.currentBudgetId else { return }
        previousMessageID = snapshot.messageID

        let current = Dictionary(uniqueKeysWithValues: snapshot.transactions.map { ($0.id, $0) })
        var currentSplitChildren: [String: [String: Transaction]] = [:]
        for parent in current.values where parent.isParent {
            currentSplitChildren[parent.id] = [:]
        }
        for child in snapshot.splitChildren {
            guard let parentID = child.parentId, currentSplitChildren[parentID] != nil else { continue }
            currentSplitChildren[parentID]?[child.id] = child
        }

        guard hasBaseline else {
            previous = current
            previousSplitChildren = currentSplitChildren
            previousBudgetID = budgetID
            hasBaseline = true
            return
        }

        if let pendingUndo = HistoryStore.pendingUndo {
            previous = current
            previousSplitChildren = currentSplitChildren
            if pendingUndo.budgetID == budgetID,
               Self.matchesPendingUndo(
                   pendingUndo,
                   current: current,
                   splitChildren: currentSplitChildren
               ) {
                HistoryStore.finishUndoRecording()
            }
            return
        }

        if isRemote || HistoryStore.recordingSuppressed {
            previous = current
            previousSplitChildren = currentSplitChildren
            return
        }

        // `isRemote` is captured at publication, but this read happens later
        // and may include a sync that landed in between. Rows another device
        // wrote since the baseline are adopted, so only local edits diff.
        var splitParentOf: [String: String] = [:]
        for (parentID, children) in previousSplitChildren {
            for childID in children.keys {
                splitParentOf[childID] = parentID
            }
        }
        for child in snapshot.splitChildren {
            splitParentOf[child.id] = child.parentId
        }
        for id in snapshot.remoteRowIDs {
            let rootID = splitParentOf[id] ?? id
            previous[rootID] = current[rootID]
            previousSplitChildren[rootID] = currentSplitChildren[rootID]
        }

        let added = current.values.filter { previous[$0.id] == nil }
        let removed = previous.values.filter { current[$0.id] == nil }
        let changed = current.values.filter {
            guard let old = previous[$0.id] else { return false }
            return !Self.samePersistedState(old, $0)
        }

        let previousParentIDs = Set(previous.values.filter(\.isParent).map(\.id))
        let currentParentIDs = Set(current.values.filter(\.isParent).map(\.id))
        let splitParentIDs = previousParentIDs.union(currentParentIDs)

        var handledRootIDs = Set<String>()
        for parentID in splitParentIDs.sorted() {
            let oldRoot = previous[parentID]
            let newRoot = current[parentID]
            let oldChildren = previousSplitChildren[parentID] ?? [:]
            let newChildren = currentSplitChildren[parentID] ?? [:]

            let rootChanged: Bool = if let oldRoot, let newRoot {
                !Self.samePersistedState(oldRoot, newRoot)
            } else {
                oldRoot != nil || newRoot != nil
            }
            let childrenChanged = !Self.samePersistedState(oldChildren, newChildren)

            guard rootChanged || childrenChanged else { continue }
            handledRootIDs.insert(parentID)

            if oldRoot == nil, let newRoot {
                let after = [newRoot]
                    + newChildren.values
                    .sorted { Self.isBefore($0, $1) }
                HistoryStore.shared.recordSnapshots(
                    budgetID: budgetID,
                    kind: .created,
                    before: [],
                    after: after
                )
            } else if let oldRoot, newRoot == nil {
                let before = [oldRoot]
                    + oldChildren.values
                    .sorted { Self.isBefore($0, $1) }
                let after = before.map { snapshot in
                    var tombstoned = snapshot
                    tombstoned.tombstone = true
                    return tombstoned
                }
                HistoryStore.shared.recordSnapshots(
                    budgetID: budgetID,
                    kind: .deleted,
                    before: before,
                    after: after
                )
            } else if let oldRoot, let newRoot {
                let allChildIDs = Set(oldChildren.keys).union(newChildren.keys).sorted()
                var before = [oldRoot]
                var after = [newRoot]

                for childID in allChildIDs {
                    if let oldChild = oldChildren[childID], let newChild = newChildren[childID] {
                        before.append(oldChild)
                        after.append(newChild)
                    } else if let newChild = newChildren[childID] {
                        var absent = newChild
                        absent.tombstone = true
                        before.append(absent)
                        after.append(newChild)
                    } else if let oldChild = oldChildren[childID] {
                        before.append(oldChild)
                        var tombstoned = oldChild
                        tombstoned.tombstone = true
                        after.append(tombstoned)
                    }
                }

                HistoryStore.shared.recordSnapshots(
                    budgetID: budgetID,
                    kind: .edited,
                    before: before,
                    after: after
                )
            }
        }

        let remainingAdded = added.filter { !handledRootIDs.contains($0.id) }
        let remainingRemoved = removed.filter { !handledRootIDs.contains($0.id) }
        let remainingChanged = changed.filter { !handledRootIDs.contains($0.id) }

        if !remainingAdded.isEmpty, remainingRemoved.isEmpty, remainingChanged.isEmpty {
            HistoryStore.shared.recordSnapshots(budgetID: budgetID, kind: .created, before: [], after: remainingAdded)
        } else if remainingAdded.isEmpty, !remainingRemoved.isEmpty, remainingChanged.isEmpty {
            HistoryStore.shared.recordSnapshots(
                budgetID: budgetID,
                kind: .deleted,
                before: remainingRemoved,
                after: remainingRemoved.map { Self.tombstoned($0) }
            )
        } else if remainingAdded.isEmpty, remainingRemoved.isEmpty, !remainingChanged.isEmpty {
            let before = remainingChanged.compactMap { previous[$0.id] }
            HistoryStore.shared.recordSnapshots(budgetID: budgetID, kind: .edited, before: before, after: remainingChanged)
        } else if !remainingAdded.isEmpty || !remainingRemoved.isEmpty || !remainingChanged.isEmpty {
            var before: [Transaction] = []
            var after: [Transaction] = []
            let ids = Set(remainingAdded.map(\.id))
                .union(remainingRemoved.map(\.id))
                .union(remainingChanged.map(\.id))
                .sorted()

            for id in ids {
                if let old = previous[id], let new = current[id] {
                    before.append(old)
                    after.append(new)
                } else if let old = previous[id] {
                    before.append(old)
                    var tombstoned = old
                    tombstoned.tombstone = true
                    after.append(tombstoned)
                } else if let new = current[id] {
                    var absent = new
                    absent.tombstone = true
                    before.append(absent)
                    after.append(new)
                }
            }

            HistoryStore.shared.recordSnapshots(
                budgetID: budgetID,
                kind: .edited,
                before: before,
                after: after
            )
        }

        previous = current
        previousSplitChildren = currentSplitChildren
        previousBudgetID = budgetID
    }

    private static func matchesPendingUndo(
        _ pending: HistoryStore.PendingUndo,
        current: [String: Transaction],
        splitChildren: [String: [String: Transaction]]
    ) -> Bool {
        var live = current
        for children in splitChildren.values {
            for child in children.values {
                live[child.id] = child
            }
        }

        for expected in pending.expected {
            if expected.tombstone {
                guard live[expected.id] == nil else { return false }
            } else {
                guard let actual = live[expected.id], expected.matchesLiveTransaction(actual) else {
                    return false
                }
            }
        }
        return pending.removedIDs.allSatisfy { live[$0] == nil }
    }

    private static func tombstoned(_ transaction: Transaction) -> Transaction {
        var copy = transaction
        copy.tombstone = true
        return copy
    }

    private static func samePersistedState(_ lhs: Transaction, _ rhs: Transaction) -> Bool {
        lhs.matchesLiveTransaction(rhs)
    }

    private static func samePersistedState(
        _ lhs: [String: Transaction],
        _ rhs: [String: Transaction]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (id, old) in lhs {
            guard let new = rhs[id], samePersistedState(old, new) else { return false }
        }
        return true
    }

    private static func isBefore(_ lhs: Transaction, _ rhs: Transaction) -> Bool {
        let lhsSort = lhs.sortOrder ?? 0
        let rhsSort = rhs.sortOrder ?? 0
        if lhsSort != rhsSort {
            return lhsSort < rhsSort
        }
        return lhs.id < rhs.id
    }
}
