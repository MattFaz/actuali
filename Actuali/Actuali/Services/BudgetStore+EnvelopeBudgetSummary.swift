import Foundation

struct EnvelopeBudgetSummary: Equatable, Sendable {
    let availableFunds: Int
    let lastMonthOverspent: Int
    let budgeted: Int
    let forNextMonth: Int
    let toBudget: Int
    let manualBuffered: Int
    let autoBuffered: Int
}

extension BudgetStore {
    /// Reconstructs the envelope summary from canonical BudgetMonth snapshots.
    func fetchEnvelopeBudgetSummary(_ month: String) async -> EnvelopeBudgetSummary? {
        guard Self.isValidBudgetMonth(month) else { return nil }

        var snapshots: [String: BudgetMonth] = [:]
        var cursor = month

        while true {
            guard let snapshot = await fetchBudgetMonthSnapshot(cursor) else { return nil }
            snapshots[cursor] = snapshot
            if Self.isSummaryBaseline(snapshot) { break }
            guard let previous = Self.shiftBudgetMonth(cursor, by: -1) else { break }
            cursor = previous
        }

        let months = snapshots.keys.sorted()
        guard !months.isEmpty else { return nil }

        var previousToBudget = 0
        var previousForNextMonth = 0

        for currentMonth in months {
            guard let current = snapshots[currentMonth], let toBudget = current.toBudget else { continue }
            let previousMonth = Self.shiftBudgetMonth(currentMonth, by: -1)
            let previous = previousMonth.flatMap { snapshots[$0] }

            let lastMonthOverspent = previous.map { Self.lastMonthOverspent($0.allCategoryBudgets) } ?? 0
            let budgeted = current.allCategoryBudgets.reduce(0) { $0 + $1.budgeted }
            let income = current.allIncomeCategories.reduce(0) { $0 + $1.received }
            let availableFunds = income + previousToBudget + previousForNextMonth
            let summary = Self.makeEnvelopeBudgetSummary(
                availableFunds: availableFunds,
                lastMonthOverspent: lastMonthOverspent,
                budgeted: budgeted,
                toBudget: toBudget,
                manualBuffered: current.buffered
            )

            if currentMonth == month {
                return summary
            }

            previousToBudget = toBudget
            previousForNextMonth = summary.forNextMonth
        }

        return nil
    }

    nonisolated static func lastMonthOverspent(_ categories: [CategoryBudget]) -> Int {
        categories.reduce(0) { total, category in
            category.carryoverEnabled ? total : total + min(0, category.available)
        }
    }

    nonisolated static func makeEnvelopeBudgetSummary(
        availableFunds: Int,
        lastMonthOverspent: Int,
        budgeted: Int,
        toBudget: Int,
        manualBuffered: Int
    ) -> EnvelopeBudgetSummary {
        let forNextMonth = availableFunds + lastMonthOverspent - budgeted - toBudget
        let autoBuffered = manualBuffered == 0 ? max(forNextMonth, 0) : 0

        return EnvelopeBudgetSummary(
            availableFunds: availableFunds,
            lastMonthOverspent: lastMonthOverspent,
            budgeted: budgeted,
            forNextMonth: forNextMonth,
            toBudget: toBudget,
            manualBuffered: manualBuffered,
            autoBuffered: autoBuffered
        )
    }

    nonisolated static func isValidBudgetMonth(_ month: String) -> Bool {
        let parts = month.split(separator: "-")
        guard parts.count == 2,
              parts[0].count == 4,
              parts[1].count == 2,
              let year = Int(parts[0]),
              let monthNumber = Int(parts[1]),
              year > 0,
              (1...12).contains(monthNumber) else { return false }
        return true
    }

    nonisolated static func isSummaryBaseline(_ budget: BudgetMonth) -> Bool {
        budget.toBudget == 0
            && budget.allIncomeCategories.allSatisfy { $0.received == 0 && $0.budgeted == 0 }
            && budget.allCategoryBudgets.allSatisfy {
                $0.budgeted == 0 && $0.spent == 0 && $0.available == 0 && $0.carryover == 0
            }
            && budget.buffered == 0
    }
}
