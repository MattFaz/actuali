import SwiftUI

struct YNABBudgetSummary: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let budget: BudgetMonth
    let showsSpent: Bool

    private var overview: YNABBudgetOverview {
        YNABBudgetOverview(
            budget: budget,
            showsSpent: showsSpent,
            currentMonth: BudgetView.currentMonthString()
        )
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    YNABOverviewStat(
                        stat: overview.leading,
                        isResult: overview.leading.label == "To Budget",
                        alignment: .leading
                    )
                    ForEach(Array(overview.columns.enumerated()), id: \.offset) { _, stat in
                        HStack {
                            Text(stat.label)
                                .foregroundStyle(.secondary)
                            Spacer()
                            YNABOverviewAmount(stat: stat, isResult: isResult(stat))
                        }
                    }
                }
            } else {
                HStack(spacing: 0) {
                    YNABOverviewStat(
                        stat: overview.leading,
                        isResult: overview.leading.label == "To Budget",
                        alignment: .leading
                    )
                        .frame(
                            width: YNABBudgetTableLayout.titleColumnWidth,
                            alignment: .leading
                        )

                    HStack(spacing: YNABBudgetTableLayout.amountColumnSpacing) {
                        ForEach(Array(overview.columns.enumerated()), id: \.offset) { _, stat in
                            YNABOverviewStat(stat: stat, isResult: isResult(stat))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .layoutPriority(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            dynamicTypeSize.isAccessibilitySize
                ? "ynabBudgetOverview.stacked"
                : "ynabBudgetOverview"
        )
    }

    private func isResult(_ stat: YNABBudgetOverview.Stat) -> Bool {
        stat.label == "Balance" || stat.label == "Projected" || stat.label == "Saved"
    }
}

private struct YNABOverviewStat: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let stat: YNABBudgetOverview.Stat
    let isResult: Bool
    var alignment: HorizontalAlignment = .trailing

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(stat.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.65)
                .allowsTightening(!dynamicTypeSize.isAccessibilitySize)
                .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
            YNABOverviewAmount(stat: stat, isResult: isResult)
        }
    }
}

private struct YNABOverviewAmount: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let stat: YNABBudgetOverview.Stat
    let isResult: Bool

    var body: some View {
        Text(budgetStore.displayYNABBudgetCell(stat.amount))
            .font(.footnote.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.35)
            .allowsTightening(!dynamicTypeSize.isAccessibilitySize)
            .foregroundStyle(resultColor)
            .animatedAmount(budgetStore.displayYNABBudgetCell(stat.amount))
            .accessibilityLabel("\(stat.label), \(budgetStore.displayBalance(stat.amount))")
    }

    private var resultColor: Color {
        guard isResult else { return .primary }
        switch YNABBalanceTone(amount: stat.amount, isMasked: budgetStore.hideBalances) {
        case .negative: return .red
        case .zero: return .secondary
        case .positive: return .green
        case .masked: return .primary
        }
    }
}

struct YNABBudgetGroupHeader: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let name: String
    let isCollapsed: Bool
    let totals: CategoryGroupTotals
    let showsSpent: Bool
    let onToggleCollapse: () -> Void

    private var layout: YNABBudgetTableLayout {
        YNABBudgetTableLayout(isTrackingBudget: false, showsSpent: showsSpent)
    }

    private var columns: [(YNABBudgetColumn, Int)] {
        layout.expenseColumns.compactMap { column in
            switch column {
            case .budgeted: (column, totals.budgeted)
            case .spent: (column, totals.spent)
            case .balance: (column, totals.balance)
            case .received: nil
            }
        }
    }

    var body: some View {
        Button(action: onToggleCollapse) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        title
                        ForEach(columns, id: \.0) { column, amount in
                            HStack {
                                Text(column.rawValue)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                YNABAmountText(amount: amount, isBalance: column == .balance)
                            }
                        }
                    }
                } else {
                    HStack(spacing: 0) {
                        title
                            .frame(
                                width: YNABBudgetTableLayout.titleColumnWidth,
                                alignment: .leading
                            )
                        HStack(spacing: YNABBudgetTableLayout.amountColumnSpacing) {
                            ForEach(columns, id: \.0) { column, amount in
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(column.rawValue)
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.65)
                                    YNABAmountText(amount: amount, isBalance: column == .balance)
                                }
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .layoutPriority(1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(Color(.secondarySystemBackground))
        .listRowInsets(EdgeInsets())
        .accessibilityIdentifier("ynabBudgetGroup.\(name)")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Toggles the group's categories")
    }

    private var title: some View {
        HStack(spacing: 6) {
            DisclosureChevron(isExpanded: !isCollapsed, font: .caption.weight(.semibold))
            Text(name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessibilityLabel: String {
        let state = isCollapsed ? "collapsed" : "expanded"
        var amounts = ["budgeted \(budgetStore.displayBalance(totals.budgeted))"]
        if layout.expenseColumns.contains(.spent) {
            amounts.append("spent \(budgetStore.displayBalance(totals.spent))")
        }
        amounts.append("balance \(budgetStore.displayBalance(totals.balance))")
        return "\(name), \(state), \(amounts.joined(separator: ", "))"
    }
}

struct YNABCategoryBudgetRow: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let category: CategoryBudget
    let showsSpent: Bool
    let showsProgressBars: Bool
    var onShowDetails: (CategoryBudget) -> Void = { _ in }
    var onEditBudget: (CategoryBudget) -> Void = { _ in }
    var onShowTransactions: (CategoryBudget, String?) -> Void = { _, _ in }
    var onMoveMoney: (CategoryBudget) -> Void = { _ in }

    private var layout: YNABBudgetTableLayout {
        YNABBudgetTableLayout(isTrackingBudget: false, showsSpent: showsSpent)
    }

    private var includesSpentColumn: Bool {
        layout.expenseColumns.contains(.spent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if dynamicTypeSize.isAccessibilitySize {
                stackedContent
            } else {
                compactContent
            }
            if showsProgressBars {
                CategoryProgressBar(
                    fraction: category.progressFraction,
                    state: category.progressState
                )
            }
        }
        .padding(.vertical, YNABBudgetTableLayout.categoryRowVerticalPadding)
        .frame(minHeight: YNABBudgetTableLayout.categoryRowMinimumHeight)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(Color(.systemBackground))
        .accessibilityIdentifier("ynabBudgetCategory.\(category.categoryId)")
    }

    private var compactContent: some View {
        HStack(spacing: 0) {
            detailButton
                .frame(
                    width: YNABBudgetTableLayout.titleColumnWidth,
                    alignment: .leading
                )

            HStack(spacing: YNABBudgetTableLayout.amountColumnSpacing) {
                Button {
                    onEditBudget(category)
                } label: {
                    YNABAmountText(amount: category.budgeted)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(editBudgetAccessibilityLabel)

                if includesSpentColumn {
                    Button {
                        onShowTransactions(category, category.month)
                    } label: {
                        YNABAmountText(amount: category.spent)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(monthTransactionsLabel)
                }

                Button {
                    onMoveMoney(category)
                } label: {
                    YNABAmountText(amount: category.available, isBalance: true)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .buttonStyle(.borderless)
                .disabled(category.available == 0)
                .accessibilityLabel(balanceActionLabel)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .layoutPriority(1)
        }
    }

    private var stackedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            detailButton
            Button {
                onEditBudget(category)
            } label: {
                stackedAmount(label: "Budgeted", amount: category.budgeted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(editBudgetAccessibilityLabel)

            if includesSpentColumn {
                Button {
                    onShowTransactions(category, category.month)
                } label: {
                    stackedAmount(label: "Spent", amount: category.spent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(monthTransactionsLabel)
            }

            Button {
                onMoveMoney(category)
            } label: {
                stackedAmount(label: "Balance", amount: category.available, isBalance: true)
            }
            .buttonStyle(.plain)
            .disabled(category.available == 0)
            .accessibilityLabel(balanceActionLabel)
        }
    }

    private var detailButton: some View {
        Button {
            onShowDetails(category)
        } label: {
            HStack(spacing: 6) {
                if showsProgressBars {
                    CompactCategoryStatusDot(state: category.progressState)
                }
                Text(category.categoryName)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(detailAccessibilityLabel)
    }

    private func stackedAmount(label: String, amount: Int, isBalance: Bool = false) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            YNABAmountText(amount: amount, isBalance: isBalance)
        }
        .contentShape(Rectangle())
    }

    private var monthTransactionsLabel: String {
        "Transactions for \(category.categoryName) in \(MonthPicker.title(for: category.month)), spent \(budgetStore.displayBalance(category.spent))"
    }

    private var editBudgetAccessibilityLabel: String {
        "Edit budgeted amount for \(category.categoryName), budgeted \(budgetStore.displayBalance(category.budgeted))"
    }

    private var detailAccessibilityLabel: String {
        let action = "Details for \(category.categoryName)"
        return showsProgressBars
            ? "\(action), \(category.progressState.statusText)"
            : action
    }

    private var balanceActionLabel: String {
        let action = category.isOverspent
            ? "Cover overspending for \(category.categoryName)"
            : "Move money from \(category.categoryName)"
        let tone = YNABBalanceTone(
            amount: category.available,
            isMasked: budgetStore.hideBalances
        )
        return "\(action), balance \(budgetStore.displayBalance(category.available)), \(tone.accessibilityStatus)"
    }
}

struct YNABIncomeGroupHeader: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let name: String
    var isCollapsed = false
    let totalBudgeted: Int
    let totalReceived: Int
    let showsBudgeted: Bool
    var onToggleCollapse: () -> Void = {}

    private var layout: YNABBudgetTableLayout {
        YNABBudgetTableLayout(isTrackingBudget: showsBudgeted, showsSpent: false)
    }

    private var columns: [(YNABBudgetColumn, Int)] {
        layout.incomeColumns.compactMap { column in
            switch column {
            case .budgeted: (column, totalBudgeted)
            case .received: (column, totalReceived)
            case .spent, .balance: nil
            }
        }
    }

    var body: some View {
        Button(action: onToggleCollapse) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        title
                        ForEach(columns, id: \.0) { column, amount in
                            HStack {
                                Text(column.rawValue)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                YNABAmountText(amount: amount)
                            }
                        }
                    }
                } else {
                    HStack(spacing: 0) {
                        title
                            .frame(
                                width: YNABBudgetTableLayout.titleColumnWidth,
                                alignment: .leading
                            )
                        HStack(spacing: YNABBudgetTableLayout.amountColumnSpacing) {
                            ForEach(columns, id: \.0) { column, amount in
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(column.rawValue)
                                        .font(.caption2)
                                    YNABAmountText(amount: amount)
                                }
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .layoutPriority(1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(Color(.secondarySystemBackground))
        .listRowInsets(EdgeInsets())
        .accessibilityIdentifier("ynabIncomeSection")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Toggles the income categories")
    }

    private var title: some View {
        HStack(spacing: 6) {
            DisclosureChevron(isExpanded: !isCollapsed, font: .caption.weight(.semibold))
            Text(name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessibilityLabel: String {
        let state = isCollapsed ? "collapsed" : "expanded"
        var amounts: [String] = []
        if showsBudgeted {
            amounts.append("budgeted \(budgetStore.displayBalance(totalBudgeted))")
        }
        amounts.append("received \(budgetStore.displayBalance(totalReceived))")
        return "\(name), \(state), \(amounts.joined(separator: ", "))"
    }
}

struct YNABIncomeCategoryRow: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let income: IncomeCategory
    let showsBudgeted: Bool
    var onShowTransactions: (IncomeCategory, String?) -> Void = { _, _ in }

    private var layout: YNABBudgetTableLayout {
        YNABBudgetTableLayout(isTrackingBudget: showsBudgeted, showsSpent: false)
    }

    private var includesBudgetedColumn: Bool {
        layout.incomeColumns.contains(.budgeted)
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    nameButton
                    if includesBudgetedColumn {
                        stackedReadOnlyAmount(label: "Budgeted", amount: income.budgeted)
                    }
                    Button {
                        onShowTransactions(income, income.month)
                    } label: {
                        HStack {
                            Text("Received")
                                .foregroundStyle(.secondary)
                            Spacer()
                            YNABAmountText(amount: income.received)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(monthTransactionsLabel)
                }
            } else {
                HStack(spacing: 0) {
                    nameButton
                        .frame(
                            width: YNABBudgetTableLayout.titleColumnWidth,
                            alignment: .leading
                        )
                    HStack(spacing: YNABBudgetTableLayout.amountColumnSpacing) {
                        if includesBudgetedColumn {
                            YNABAmountText(amount: income.budgeted)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .accessibilityLabel(budgetedAccessibilityLabel)
                                .accessibilityIdentifier("ynabIncomeBudgeted.\(income.categoryId)")
                        }
                        Button {
                            onShowTransactions(income, income.month)
                        } label: {
                            YNABAmountText(amount: income.received)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(monthTransactionsLabel)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .layoutPriority(1)
                }
            }
        }
        .padding(.vertical, YNABBudgetTableLayout.categoryRowVerticalPadding)
        .frame(minHeight: YNABBudgetTableLayout.categoryRowMinimumHeight)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(Color(.systemBackground))
        .accessibilityIdentifier("ynabIncomeCategory.\(income.categoryId)")
    }

    private var nameButton: some View {
        Button {
            onShowTransactions(income, nil)
        } label: {
            Text(income.categoryName)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("All transactions for \(income.categoryName)")
    }

    private func stackedReadOnlyAmount(label: String, amount: Int) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            YNABAmountText(amount: amount)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(budgetedAccessibilityLabel)
        .accessibilityIdentifier("ynabIncomeBudgeted.\(income.categoryId)")
    }

    private var budgetedAccessibilityLabel: String {
        "Budgeted for \(income.categoryName), \(budgetStore.displayBalance(income.budgeted))"
    }

    private var monthTransactionsLabel: String {
        "Transactions for \(income.categoryName) in \(MonthPicker.title(for: income.month)), received \(budgetStore.displayBalance(income.received))"
    }
}

private struct YNABAmountText: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let amount: Int
    var isBalance = false

    var body: some View {
        Text(budgetStore.displayYNABBudgetCell(amount))
            .font(.footnote.weight(isBalance ? .semibold : .regular))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.35)
            .allowsTightening(!dynamicTypeSize.isAccessibilitySize)
            .foregroundStyle(foregroundColor)
            .animatedAmount(budgetStore.displayYNABBudgetCell(amount))
            .padding(.horizontal, isBalance ? 5 : 0)
            .padding(.vertical, isBalance ? 2 : 0)
            .background {
                if isBalance {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(foregroundColor.opacity(budgetStore.hideBalances ? 0.08 : 0.14))
                }
            }
            .accessibilityLabel(budgetStore.displayBalance(amount))
    }

    private var foregroundColor: Color {
        guard isBalance else {
            return amount == 0 ? .secondary : .primary
        }
        switch YNABBalanceTone(amount: amount, isMasked: budgetStore.hideBalances) {
        case .negative: return .red
        case .zero: return .secondary
        case .positive: return .green
        case .masked: return .primary
        }
    }
}

extension View {
    @ViewBuilder
    func budgetListStyle(for style: BudgetDisplayStyle) -> some View {
        switch style {
        case .ynab:
            listStyle(.plain)
        case .clean, .detailed:
            self
        }
    }
}

private extension BudgetStore {
    @MainActor
    func displayYNABBudgetCell(_ cents: Int) -> String {
        hideBalances
            ? Self.hiddenBalanceText
            : CurrencyAmountFormat.symbolLessString(
                cents: cents,
                currencyCode: currencyCode
            )
    }
}
