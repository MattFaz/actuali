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

    /// Number of expense categories in the red — drives the Budget tab badge.
    var overspentCount: Int {
        categoryBudgets.count(where: \.isOverspent)
    }

    /// The categories behind `overspentCount`, worst first, so the badge can
    /// be explained instead of leaving the user to hunt through the table
    /// (GH #138).
    var overspentCategories: [CategoryBudget] {
        categoryBudgets
            .filter(\.isOverspent)
            .sorted { $0.available < $1.available }
    }

    /// Categories with neither assigned money nor carried balance/activity.
    /// This is a check-in prompt, not a target calculation.
    var unassignedCategories: [CategoryBudget] {
        categoryBudgets
            .filter { $0.progressState == .unassigned }
            .sorted { ($0.groupSortOrder, $0.categorySortOrder) < ($1.groupSortOrder, $1.categorySortOrder) }
    }

    /// Healthy categories that have consumed at least 80% of their available
    /// capacity. Overspent and fully spent categories have separate guidance.
    var approachingLimitCategories: [CategoryBudget] {
        categoryBudgets
            .filter { !$0.isOverspent && $0.available > 0 && $0.spent < 0 && $0.progressFraction >= 0.8 }
            .sorted { $0.progressFraction > $1.progressFraction }
    }

    var totalBudgeted: Int {
        categoryBudgets.reduce(0) { $0 + $1.budgeted }
    }

    /// Net activity across expense categories — inflows (refunds,
    /// reimbursements) offset outflows, matching the Spent total in Actual's
    /// web UI (GH #212).
    var totalSpent: Int {
        categoryBudgets.reduce(0) { $0 + $1.spent }
    }

    var totalAvailable: Int {
        categoryBudgets.reduce(0) { $0 + $1.available }
    }

    var totalIncome: Int {
        incomeCategories.reduce(0) { $0 + $1.received }
    }

    /// Sum of budgeted amounts on income categories. Only meaningful for
    /// tracking budgets, which can budget income. Mirrors loot-core
    /// tracking.ts `total-budget-income`.
    var totalBudgetedIncome: Int {
        incomeCategories.reduce(0) { $0 + $1.budgeted }
    }

    /// Actual money kept this month: income received minus what actually went
    /// out. Mirrors loot-core tracking.ts `real-saved`
    /// (`total-income - -total-spent`); `totalSpent` is negative, so this adds.
    var savedActual: Int {
        totalIncome + totalSpent
    }

    /// What the budget projects will be kept: budgeted income minus budgeted
    /// expenses. Mirrors loot-core tracking.ts `total-saved`.
    var projectedSavings: Int {
        totalBudgetedIncome - totalBudgeted
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
    var available: Int // In cents (budgeted + spent + carryover)
    var carryover: Int

    var isOverspent: Bool {
        available < 0
    }

    /// Overspending carried in from earlier months (negative, or 0 when the
    /// carryover is a credit). Actual's web UI doesn't surface this either,
    /// so a category can sit in the red with no visible cause in the current
    /// month — the trigger for GH #138.
    var rolledOverOverspending: Int {
        min(carryover, 0)
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

    /// A compact, mode-neutral description of where this category stands.
    /// Views translate it into envelope or tracking language as needed.
    var progressState: CategoryProgressState {
        if available < 0 { return .overspent }
        if available == 0, spent != 0 { return .spent }
        if available == 0, budgeted == 0, carryover == 0 { return .unassigned }
        if spent != 0 { return .spending }
        return .funded
    }
}

enum CategoryProgressState: Equatable {
    case unassigned
    case funded
    case spending
    case spent
    case overspent
}

struct QuickAssignSuggestion: Identifiable, Equatable {
    enum Kind: String {
        case spentLastMonth
        case averageSpent
        case assignedLastMonth
        case resetAvailable
        case setToZero
    }

    var id: Kind { kind }
    let kind: Kind
    let amount: Int
}

extension CategoryBudget {
    /// Suggested *final assigned amounts*, never deltas. This keeps the UI on
    /// Actual's existing setBudgetAmount path and makes every choice previewable.
    func quickAssignSuggestions(history: [CategoryBudget]) -> [QuickAssignSuggestion] {
        var suggestions: [QuickAssignSuggestion] = []
        if let lastMonth = history.first {
            let spent = abs(min(lastMonth.spent, 0))
            if spent > 0 {
                suggestions.append(.init(kind: .spentLastMonth, amount: spent))
            }
            if lastMonth.budgeted != 0 {
                suggestions.append(.init(kind: .assignedLastMonth, amount: lastMonth.budgeted))
            }
        }

        let spending = history.map { abs(min($0.spent, 0)) }
        if !spending.isEmpty {
            let average = Int((Double(spending.reduce(0, +)) / Double(spending.count)).rounded())
            if average > 0 {
                suggestions.append(.init(kind: .averageSpent, amount: average))
            }
        }

        if available != 0 {
            suggestions.append(.init(kind: .resetAvailable, amount: budgeted - available))
        }
        if budgeted != 0 {
            suggestions.append(.init(kind: .setToZero, amount: 0))
        }
        return suggestions
    }
}

/// Column sums for one category group, shown in the detailed style's group
/// header the way the PWA's table totals its group rows. Always built from a
/// group's full category list — "Hide Spent Categories" trims which rows are
/// drawn, and a header total that quietly dropped those categories would
/// disagree with the summary card at the top of the table.
struct CategoryGroupTotals: Equatable {
    let budgeted: Int
    let spent: Int
    let balance: Int

    init(_ categories: [CategoryBudget]) {
        budgeted = categories.reduce(0) { $0 + $1.budgeted }
        spent = categories.reduce(0) { $0 + $1.spent }
        balance = categories.reduce(0) { $0 + $1.available }
    }
}
