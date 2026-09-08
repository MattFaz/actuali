import Foundation

enum CompactBudgetColumn: String, Equatable {
    case budgeted = "Budgeted"
    case spent = "Spent"
    case balance = "Balance"
    case received = "Received"

    var label: String {
        label(locale: .autoupdatingCurrent)
    }

    func label(locale: Locale, bundle: Bundle = .main) -> String {
        ReportStrings.text(rawValue, locale: locale, bundle: bundle)
    }
}

enum CompactBudgetAccessibility {
    static func balanceStatus(_ tone: CompactBalanceTone, locale: Locale, bundle: Bundle = .main) -> String {
        let key: String
        switch tone {
        case .negative: key = "budget.balanceStatus.negative"
        case .zero: key = "budget.balanceStatus.zero"
        case .positive: key = "budget.balanceStatus.positive"
        case .masked: key = "budget.balanceStatus.hidden"
        }
        return ReportStrings.text(key, locale: locale, bundle: bundle)
    }

    static func groupHeader(
        name: String,
        state: String,
        budgeted: String,
        spent: String?,
        balance: String,
        locale: Locale,
        bundle: Bundle = .main
    ) -> String {
        let key = spent == nil
            ? "%@, %@, budgeted %@, balance %@"
            : "%@, %@, budgeted %@, spent %@, balance %@"
        let arguments: [any CVarArg] = spent == nil
            ? [name, state, budgeted, balance]
            : [name, state, budgeted, spent!, balance]
        return ReportStrings.format(key, arguments: arguments, locale: locale, bundle: bundle)
    }

    static func incomeHeader(
        name: String,
        state: String,
        budgeted: String?,
        received: String,
        locale: Locale,
        bundle: Bundle = .main
    ) -> String {
        let key = budgeted == nil
            ? "%@, %@, received %@"
            : "%@, %@, budgeted %@, received %@"
        let arguments: [any CVarArg] = budgeted == nil
            ? [name, state, received]
            : [name, state, budgeted!, received]
        return ReportStrings.format(key, arguments: arguments, locale: locale, bundle: bundle)
    }

    static func monthTransactions(
        category: String,
        month: String,
        amountLabel: String,
        amount: String,
        locale: Locale,
        bundle: Bundle = .main
    ) -> String {
        ReportStrings.format("Transactions for %@ in %@, %@ %@", category, month, amountLabel, amount, locale: locale, bundle: bundle)
    }

    static func editBudget(category: String, amount: String, locale: Locale, bundle: Bundle = .main) -> String {
        ReportStrings.format("Edit budgeted amount for %@, budgeted %@", category, amount, locale: locale, bundle: bundle)
    }

    static func details(category: String, status: String?, locale: Locale, bundle: Bundle = .main) -> String {
        if let status {
            return ReportStrings.format("Details for %@, %@", category, status, locale: locale, bundle: bundle)
        }
        return ReportStrings.format("Details for %@", category, locale: locale, bundle: bundle)
    }

    static func balanceAction(category: String, isOverspent: Bool, balance: String, tone: String, locale: Locale, bundle: Bundle = .main) -> String {
        let key = isOverspent
            ? "Cover overspending for %@, balance %@, %@"
            : "Move money from %@, balance %@, %@"
        return ReportStrings.format(key, category, balance, tone, locale: locale, bundle: bundle)
    }

    static func incomeBudgeted(category: String, amount: String, locale: Locale, bundle: Bundle = .main) -> String {
        ReportStrings.format("Budgeted for %@, %@", category, amount, locale: locale, bundle: bundle)
    }
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
    let incomeColumns: [CompactBudgetColumn?]

    init(isTrackingBudget: Bool, showsSpent: Bool) {
        expenseColumns = showsSpent
            ? [.budgeted, .spent, .balance]
            : [.budgeted, .balance]
        incomeColumns = expenseColumns.map { column in
            switch column {
            case .budgeted: isTrackingBudget ? .budgeted : nil
            case .spent: nil
            case .balance: .received
            case .received: nil
            }
        }
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
        enum Kind: String, Equatable {
            case toBudget
            case income
            case budgeted
            case spent
            case saved
            case projected
            case balance
        }

        let kind: Kind
        let amount: Int

        var label: String {
            label(locale: .autoupdatingCurrent)
        }

        func label(locale: Locale, bundle: Bundle = .main) -> String {
            switch kind {
            case .toBudget: ReportStrings.text("To Budget", locale: locale, bundle: bundle)
            case .income: ReportStrings.text("Income", locale: locale, bundle: bundle)
            case .budgeted: ReportStrings.text("Budgeted", locale: locale, bundle: bundle)
            case .spent: ReportStrings.text("Spent", locale: locale, bundle: bundle)
            case .saved: ReportStrings.text("Saved", locale: locale, bundle: bundle)
            case .projected: ReportStrings.text("Projected", locale: locale, bundle: bundle)
            case .balance: ReportStrings.text("Balance", locale: locale, bundle: bundle)
            }
        }
    }

    let leading: Stat
    let columns: [Stat]

    init(budget: BudgetMonth, showsSpent: Bool, currentMonth: String) {
        if let toBudget = budget.toBudget {
            leading = Stat(kind: .toBudget, amount: toBudget)
        } else {
            leading = Stat(kind: .income, amount: budget.totalIncome)
        }

        var columns = [Stat(kind: .budgeted, amount: budget.totalBudgeted)]
        if showsSpent {
            columns.append(Stat(kind: .spent, amount: budget.totalSpent))
        }
        if budget.isTrackingBudget {
            columns.append(
                budget.month < currentMonth
                    ? Stat(kind: .saved, amount: budget.savedActual)
                    : Stat(kind: .projected, amount: budget.projectedSavings)
            )
        } else {
            columns.append(Stat(kind: .balance, amount: budget.totalAvailable))
        }
        self.columns = columns
    }
}
