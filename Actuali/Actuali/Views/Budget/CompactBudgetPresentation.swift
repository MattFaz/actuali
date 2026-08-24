import Foundation

enum CompactBudgetColumn: String, Equatable {
    case budgeted = "Budgeted"
    case spent = "Spent"
    case balance = "Balance"
    case received = "Received"
}

enum CompactBalanceTone: Equatable {
    case negative
    case zero
    case positive
    case masked

    init(amount: Int, isMasked: Bool) {
        if isMasked {
            self = .masked
        } else if amount < 0 {
            self = .negative
        } else if amount == 0 {
            self = .zero
        } else {
            self = .positive
        }
    }

    var accessibilityStatus: String {
        switch self {
        case .negative: "negative"
        case .zero: "zero"
        case .positive: "positive"
        case .masked: "hidden"
        }
    }
}

struct CompactBudgetTableLayout: Equatable {
    static let titleColumnWidth: CGFloat = 145
    static let amountColumnSpacing: CGFloat = 4
    static let categoryRowVerticalPadding: CGFloat = 12
    static let categoryRowMinimumHeight: CGFloat = 44

    let expenseColumns: [CompactBudgetColumn]
    let incomeColumns: [CompactBudgetColumn]

    init(isTrackingBudget: Bool, showsSpent: Bool) {
        expenseColumns = showsSpent
            ? [.budgeted, .spent, .balance]
            : [.budgeted, .balance]
        incomeColumns = isTrackingBudget
            ? [.budgeted, .received]
            : [.received]
    }
}

struct CompactBudgetGroupHeaderPresentation: Equatable {
    struct Column: Equatable {
        let type: CompactBudgetColumn
        let amount: Int
    }

    let columns: [Column]

    init(totals: CategoryGroupTotals?, showsSpent: Bool) {
        guard let totals else {
            columns = []
            return
        }

        let layout = CompactBudgetTableLayout(isTrackingBudget: false, showsSpent: showsSpent)
        columns = layout.expenseColumns.compactMap { column in
            switch column {
            case .budgeted: Column(type: column, amount: totals.budgeted)
            case .spent: Column(type: column, amount: totals.spent)
            case .balance: Column(type: column, amount: totals.balance)
            case .received: nil
            }
        }
    }
}

struct CompactBudgetOverview: Equatable {
    struct Stat: Equatable {
        let label: String
        let amount: Int
    }

    let leading: Stat
    let columns: [Stat]

    init(budget: BudgetMonth, showsSpent: Bool, currentMonth: String) {
        if let toBudget = budget.toBudget {
            leading = Stat(label: "To Budget", amount: toBudget)
        } else {
            leading = Stat(label: "Income", amount: budget.totalIncome)
        }

        var columns = [Stat(label: "Budgeted", amount: budget.totalBudgeted)]
        if showsSpent {
            columns.append(Stat(label: "Spent", amount: budget.totalSpent))
        }
        if budget.isTrackingBudget {
            columns.append(
                budget.month < currentMonth
                    ? Stat(label: "Saved", amount: budget.savedActual)
                    : Stat(label: "Projected", amount: budget.projectedSavings)
            )
        } else {
            columns.append(Stat(label: "Balance", amount: budget.totalAvailable))
        }
        self.columns = columns
    }
}
