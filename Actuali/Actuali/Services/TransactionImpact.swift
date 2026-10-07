import Foundation
import UIKit

/// How a transaction change moved one budget category's available balance,
/// shown by `TransactionImpactPopup`.
struct TransactionImpactCue: Identifiable, Equatable {
    let categoryId: String
    let categoryName: String
    /// The budget month the balance belongs to ("2026-10").
    let month: String
    let balanceBeforeCents: Int
    let balanceAfterCents: Int

    var id: String {
        "\(month)-\(categoryId)"
    }

    var deltaCents: Int {
        balanceAfterCents - balanceBeforeCents
    }

    var isExpense: Bool {
        deltaCents < 0
    }
}

/// One category in one budget month, the unit a balance is compared by.
struct TransactionImpactTarget: Hashable {
    let month: String
    let categoryId: String
}

/// Pure rules behind the balance impact popup.
enum TransactionImpact {
    /// "2026-10" for a YYYYMMDD day integer, the budget month it falls in.
    nonisolated static func month(forDate date: Int) -> String {
        String(format: "%04d-%02d", date / 10000, (date % 10000) / 100)
    }

    /// One cue per category whose balance moved. Categories missing from
    /// either snapshot (income, hidden away, deleted) and unchanged balances
    /// show nothing. Ordered by month, then name, so the cards are stable.
    nonisolated static func cues(
        before: [TransactionImpactTarget: (name: String, available: Int)],
        after: [TransactionImpactTarget: (name: String, available: Int)]
    ) -> [TransactionImpactCue] {
        before.keys.compactMap { target -> TransactionImpactCue? in
            guard let was = before[target], let now = after[target],
                  was.available != now.available else { return nil }
            return TransactionImpactCue(
                categoryId: target.categoryId, categoryName: now.name, month: target.month,
                balanceBeforeCents: was.available, balanceAfterCents: now.available
            )
        }
        .sorted { ($0.month, $0.categoryName) < ($1.month, $1.categoryName) }
    }

    /// How long the popup stays up before it dismisses itself.
    static let autoDismissSeconds = 4.2
}

extension BudgetStore {
    /// The budget categories a set of transactions sits in, by month: a
    /// split's lines count, transfers and off-budget accounts don't.
    func impactTargets(for transactions: [Transaction]) async -> Set<TransactionImpactTarget> {
        var targets = Set<TransactionImpactTarget>()
        for tx in transactions where tx.transferId == nil && tx.transferAcct == nil
            && !offBudgetAccountIds.contains(tx.accountId) {
            let month = TransactionImpact.month(forDate: tx.date)
            var categoryIds: [String] = []
            if tx.isParent, let database = databaseForLogger {
                let children = await (try? database.fetchChildTransactions(parentId: tx.id)) ?? []
                categoryIds = children.compactMap(\.categoryId)
            } else if let categoryId = tx.categoryId {
                categoryIds = [categoryId]
            }
            for categoryId in categoryIds {
                targets.insert(TransactionImpactTarget(month: month, categoryId: categoryId))
            }
        }
        return targets
    }

    /// The same, for a transaction form that is about to be saved.
    func impactTargets(for form: TransactionForm) -> Set<TransactionImpactTarget> {
        guard form.type != .transfer, !offBudgetAccountIds.contains(form.accountId) else { return [] }
        let month = TransactionImpact.month(forDate: Transaction.yyyymmdd(from: form.date))
        let ids = form.splits.isEmpty ? [form.categoryId] : form.splits.map(\.categoryId)
        return Set(ids.compactMap { $0.map { TransactionImpactTarget(month: month, categoryId: $0) } })
    }

    private func availableBalances(
        _ targets: Set<TransactionImpactTarget>,
        refreshedMonth: BudgetMonth? = nil
    ) async -> [TransactionImpactTarget: (name: String, available: Int)] {
        guard let database = databaseForLogger else { return [:] }
        var result: [TransactionImpactTarget: (name: String, available: Int)] = [:]
        for month in Set(targets.map(\.month)) {
            let budget: BudgetMonth? = if let refreshedMonth, refreshedMonth.month == month {
                refreshedMonth
            } else {
                try? await database.fetchBudgetMonth(month: month)
            }
            guard let budget else { continue }
            for category in budget.categoryBudgets {
                let target = TransactionImpactTarget(month: month, categoryId: category.categoryId)
                if targets.contains(target) {
                    result[target] = (category.categoryName, category.available)
                }
            }
        }
        return result
    }

    /// Run a change to transactions and show the popup for the categories it
    /// moved. `targets` are read before the change; callers that also change
    /// where a row lands (an edit) pass both the old and the new categories.
    func withImpactCue<T>(
        touching targets: Set<TransactionImpactTarget>,
        _ work: () async throws -> T
    ) async rethrows -> T {
        // Hidden balances stay hidden: no popup rather than one full of dots.
        guard showTransactionImpactCue, !hideBalances, !targets.isEmpty, let database = databaseForLogger else {
            return try await work()
        }
        let budgetId = currentBudgetId
        let displayedBefore = currentBudgetMonth
        let before = await availableBalances(targets)
        let result = try await work()
        guard databaseForLogger === database, currentBudgetId == budgetId,
              showTransactionImpactCue, !hideBalances else { return result }
        // A successful write refreshes the displayed month already. Reuse
        // that snapshot when it changed, instead of walking its history again.
        let refreshedMonth = currentBudgetMonth != displayedBefore ? currentBudgetMonth : nil
        let after = await availableBalances(targets, refreshedMonth: refreshedMonth)
        guard databaseForLogger === database, currentBudgetId == budgetId else { return result }
        showImpactCues(TransactionImpact.cues(before: before, after: after))
        return result
    }

    /// Convenience for changes described by the transactions they touch.
    func withImpactCue<T>(
        for transactions: [Transaction],
        _ work: () async throws -> T
    ) async rethrows -> T {
        guard showTransactionImpactCue, !hideBalances else { return try await work() }
        let targets = await impactTargets(for: transactions)
        return try await withImpactCue(touching: targets, work)
    }

    private func showImpactCues(_ cues: [TransactionImpactCue]) {
        guard showTransactionImpactCue, !hideBalances else { return }
        impactDismissGeneration += 1
        let generation = impactDismissGeneration
        transactionImpactCues = cues
        guard !cues.isEmpty else { return }
        UIAccessibility.post(notification: .announcement, argument: cues.map(spokenImpactText).joined(separator: ". "))
        impactDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TransactionImpact.autoDismissSeconds))
            guard !Task.isCancelled else { return }
            guard let self, self.impactDismissGeneration == generation else { return }
            self.transactionImpactCues = []
        }
    }

    func dismissTransactionImpactCues() {
        impactDismissGeneration += 1
        impactDismissTask?.cancel()
        transactionImpactCues = []
    }

    /// "Groceries: 100.00 to 90.00, down 10.00" for VoiceOver.
    func spokenImpactText(_ cue: TransactionImpactCue) -> String {
        let before = displayBalance(cue.balanceBeforeCents)
        let after = displayBalance(cue.balanceAfterCents)
        let change = displayBalance(abs(cue.deltaCents))
        let format = cue.isExpense
            ? String(localized: "%@: %@ to %@, down %@")
            : String(localized: "%@: %@ to %@, up %@")
        let name = cue.month == TransactionImpact.month(forDate: Transaction.yyyymmdd(from: Date()))
            ? cue.categoryName
            : String(format: String(localized: "%@ (%@)"), cue.categoryName, MonthPicker.title(for: cue.month))
        return String(format: format, name, before, after, change)
    }
}
