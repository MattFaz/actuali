import Foundation

struct BudgetMonth: Identifiable, Hashable {
    var id: String { month }
    let month: String // Format: "2025-01"
    var categoryBudgets: [CategoryBudget]

    /// Income categories for the month, shown as their own section below the
    /// expense groups — mirrors the Income group at the bottom of the Actual
    /// web UI's budget table.
    var incomeCategories: [IncomeCategory] = []

    /// Unallocated funds for this month ("To Budget" in Actual): income plus
    /// what last month left over, minus everything budgeted. Only meaningful
    /// for envelope budgets — nil for tracking budgets.
    var toBudget: Int?

    var totalBudgeted: Int {
        categoryBudgets.reduce(0) { $0 + $1.budgeted }
    }

    var totalSpent: Int {
        categoryBudgets.reduce(0) { $0 + $1.spent }
    }

    /// Money that actually left the budget this month — inflows (refunds,
    /// reimbursements) are excluded so a positive-heavy month doesn't show
    /// a misleading "Spent" total.
    var totalOutflow: Int {
        categoryBudgets.reduce(0) { $0 + $1.outflow }
    }

    var totalAvailable: Int {
        categoryBudgets.reduce(0) { $0 + $1.available }
    }

    var totalIncome: Int {
        incomeCategories.reduce(0) { $0 + $1.received }
    }
}

struct IncomeCategory: Identifiable, Hashable {
    var id: String { "\(month)-\(categoryId)" }
    let month: String
    let categoryId: String
    var categoryName: String
    var groupName: String
    var sortOrder: Double
    var budgeted: Int // In cents; only meaningful for tracking budgets
    var received: Int // In cents (positive when money came in)
}

struct CategoryBudget: Identifiable, Hashable {
    var id: String { "\(month)-\(categoryId)" }
    let month: String
    let categoryId: String
    var categoryName: String
    var groupId: String
    var groupName: String
    var groupSortOrder: Double
    var categorySortOrder: Double
    var budgeted: Int // In cents
    var spent: Int // In cents (negative value, net of inflows)
    var outflow: Int = 0 // In cents (negative transactions only)
    var available: Int // In cents (budgeted + spent + carryover)
    var carryover: Int

    var isOverspent: Bool {
        available < 0
    }

    /// Fill for the row's progress bar, 0...1. Measured against what the
    /// category actually had to spend this month (spent + remaining
    /// available), so the bar agrees with the displayed Available amount
    /// even when carryover makes it diverge from the budgeted figure.
    var progressFraction: Double {
        let spentAmount = Double(abs(spent))
        let capacity = spentAmount + Double(max(available, 0))
        guard capacity > 0 else { return 0 }
        return min(spentAmount / capacity, 1)
    }

    /// A bar with no budget and no activity carries no information.
    var showsProgressBar: Bool {
        budgeted != 0 || spent != 0
    }
}
