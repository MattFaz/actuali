import Foundation

struct BudgetMonth: Identifiable, Hashable {
    var id: String { month }
    let month: String // Format: "2025-01"
    var categoryBudgets: [CategoryBudget]

    var totalBudgeted: Int {
        categoryBudgets.reduce(0) { $0 + $1.budgeted }
    }

    var totalSpent: Int {
        categoryBudgets.reduce(0) { $0 + $1.spent }
    }

    var totalAvailable: Int {
        categoryBudgets.reduce(0) { $0 + $1.available }
    }
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
    var spent: Int // In cents (negative value)
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
