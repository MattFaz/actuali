import SwiftUI

struct ListBudgetSummary: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let budget: BudgetMonth
    let showsSpent: Bool

    private var overview: ListBudgetOverview {
        ListBudgetOverview(
            budget: budget,
            showsSpent: showsSpent,
            currentMonth: BudgetView.currentMonthString()
        )
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    ListOverviewStat(
                        stat: overview.leading,
                        isResult: overview.leading.label == "To Budget",
                        alignment: .leading
                    )
                    ForEach(Array(overview.columns.enumerated()), id: \.offset) { _, stat in
                        HStack {
                            Text(stat.label)
                                .foregroundStyle(.secondary)
                            Spacer()
                            ListOverviewAmount(stat: stat, isResult: isResult(stat))
                        }
                    }
                }
            } else {
                HStack(spacing: 0) {
                    ListOverviewStat(
                        stat: overview.leading,
                        isResult: overview.leading.label == "To Budget",
                        alignment: .leading
                    )
                        .frame(
                            width: ListBudgetTableLayout.titleColumnWidth,
                            alignment: .leading
                        )

                    HStack(spacing: ListBudgetTableLayout.amountColumnSpacing) {
                        ForEach(Array(overview.columns.enumerated()), id: \.offset) { _, stat in
                            ListOverviewStat(stat: stat, isResult: isResult(stat))
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
                ? "listBudgetOverview.stacked"
                : "listBudgetOverview"
        )
    }

    private func isResult(_ stat: ListBudgetOverview.Stat) -> Bool {
        stat.label == "Balance" || stat.label == "Projected" || stat.label == "Saved"
    }
}

private struct ListOverviewStat: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let stat: ListBudgetOverview.Stat
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
            ListOverviewAmount(stat: stat, isResult: isResult)
        }
    }
}

private struct ListOverviewAmount: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let stat: ListBudgetOverview.Stat
    let isResult: Bool

    var body: some View {
        Text(budgetStore.displayListBudgetCell(stat.amount))
            .font(.footnote.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.35)
            .allowsTightening(!dynamicTypeSize.isAccessibilitySize)
            .foregroundStyle(resultColor)
            .animatedAmount(budgetStore.displayListBudgetCell(stat.amount))
            .accessibilityLabel("\(stat.label), \(budgetStore.displayBalance(stat.amount))")
    }

    private var resultColor: Color {
        guard isResult else { return .primary }
        switch ListBalanceTone(amount: stat.amount, isMasked: budgetStore.hideBalances) {
        case .negative: return .red
        case .zero: return .secondary
        case .positive: return .green
        case .masked: return .primary
        }
    }
}

struct ListBudgetGroupHeader: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let name: String
    let isCollapsed: Bool
    let totals: CategoryGroupTotals?
    let showsSpent: Bool
    let onToggleCollapse: () -> Void

    private var presentation: ListBudgetGroupHeaderPresentation {
        ListBudgetGroupHeaderPresentation(totals: totals, showsSpent: showsSpent)
    }

    /// Keep the same column geometry when totals are hidden so toggling the
    /// preference only changes the content, not the header's dimensions.
    private var columnsForLayout: [ListBudgetGroupHeaderPresentation.Column] {
        guard totals == nil else { return presentation.columns }
        return ListBudgetTableLayout(isTrackingBudget: false, showsSpent: showsSpent)
            .expenseColumns
            .map { .init(type: $0, amount: 0) }
    }

    var body: some View {
        Button(action: onToggleCollapse) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        title
                        ForEach(columnsForLayout, id: \.type) { column in
                            HStack {
                                Text(column.type.rawValue)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                ListAmountText(
                                    amount: column.amount,
                                    isBalance: column.type == .balance
                                )
                            }
                        }
                        .opacity(totals == nil ? 0 : 1)
                        .accessibilityHidden(totals == nil)
                    }
                } else {
                    HStack(spacing: 0) {
                        title
                            .frame(
                                width: ListBudgetTableLayout.titleColumnWidth,
                                alignment: .leading
                            )
                        HStack(spacing: ListBudgetTableLayout.amountColumnSpacing) {
                            ForEach(columnsForLayout, id: \.type) { column in
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(column.type.rawValue)
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.65)
                                    ListAmountText(
                                        amount: column.amount,
                                        isBalance: column.type == .balance
                                    )
                                }
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .layoutPriority(1)
                        .opacity(totals == nil ? 0 : 1)
                        .accessibilityHidden(totals == nil)
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
        .accessibilityIdentifier("listBudgetGroup.\(name)")
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
        guard let totals else { return "\(name), \(state)" }
        var amounts = ["budgeted \(budgetStore.displayBalance(totals.budgeted))"]
        if showsSpent {
            amounts.append("spent \(budgetStore.displayBalance(totals.spent))")
        }
        amounts.append("balance \(budgetStore.displayBalance(totals.balance))")
        return "\(name), \(state), \(amounts.joined(separator: ", "))"
    }
}

struct ListCategoryBudgetRow: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let category: CategoryBudget
    let showsSpent: Bool
    let showsProgressBars: Bool
    var onShowDetails: (CategoryBudget) -> Void = { _ in }
    var onEditBudget: (CategoryBudget) -> Void = { _ in }
    var onShowTransactions: (CategoryBudget, String?) -> Void = { _, _ in }
    var onMoveMoney: (CategoryBudget) -> Void = { _ in }

    private var layout: ListBudgetTableLayout {
        ListBudgetTableLayout(isTrackingBudget: false, showsSpent: showsSpent)
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
        .padding(.vertical, ListBudgetTableLayout.categoryRowVerticalPadding)
        .frame(minHeight: ListBudgetTableLayout.categoryRowMinimumHeight)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(Color(.systemBackground))
        .accessibilityIdentifier("listBudgetCategory.\(category.categoryId)")
    }

    private var compactContent: some View {
        HStack(spacing: 0) {
            detailButton
                .frame(
                    width: ListBudgetTableLayout.titleColumnWidth,
                    alignment: .leading
                )

            HStack(spacing: ListBudgetTableLayout.amountColumnSpacing) {
                Button {
                    onEditBudget(category)
                } label: {
                    ListAmountText(amount: category.budgeted)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(editBudgetAccessibilityLabel)

                if includesSpentColumn {
                    Button {
                        onShowTransactions(category, category.month)
                    } label: {
                        ListAmountText(amount: category.spent)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(monthTransactionsLabel)
                }

                Button {
                    onMoveMoney(category)
                } label: {
                    ListAmountText(amount: category.available, isBalance: true)
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
            ListAmountText(amount: amount, isBalance: isBalance)
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
        let tone = ListBalanceTone(
            amount: category.available,
            isMasked: budgetStore.hideBalances
        )
        return "\(action), balance \(budgetStore.displayBalance(category.available)), \(tone.accessibilityStatus)"
    }
}

struct ListIncomeGroupHeader: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let name: String
    let totalBudgeted: Int
    let totalReceived: Int
    let showsBudgeted: Bool

    private var layout: ListBudgetTableLayout {
        ListBudgetTableLayout(isTrackingBudget: showsBudgeted, showsSpent: false)
    }

    private var columns: [(ListBudgetColumn, Int)] {
        layout.incomeColumns.compactMap { column in
            switch column {
            case .budgeted: (column, totalBudgeted)
            case .received: (column, totalReceived)
            case .spent, .balance: nil
            }
        }
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                    ForEach(columns, id: \.0) { column, amount in
                        HStack {
                            Text(column.rawValue)
                                .foregroundStyle(.secondary)
                            Spacer()
                            ListAmountText(amount: amount)
                        }
                    }
                }
            } else {
                HStack(spacing: 0) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(
                            width: ListBudgetTableLayout.titleColumnWidth,
                            alignment: .leading
                        )
                    HStack(spacing: ListBudgetTableLayout.amountColumnSpacing) {
                        ForEach(columns, id: \.0) { column, amount in
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(column.rawValue)
                                    .font(.caption2)
                                ListAmountText(amount: amount)
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
        .foregroundStyle(.primary)
        .background(Color(.secondarySystemBackground))
        .listRowInsets(EdgeInsets())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("listIncomeSection")
    }
}

struct ListIncomeCategoryRow: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let income: IncomeCategory
    let showsBudgeted: Bool
    var onShowTransactions: (IncomeCategory, String?) -> Void = { _, _ in }

    private var layout: ListBudgetTableLayout {
        ListBudgetTableLayout(isTrackingBudget: showsBudgeted, showsSpent: false)
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
                            ListAmountText(amount: income.received)
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
                            width: ListBudgetTableLayout.titleColumnWidth,
                            alignment: .leading
                        )
                    HStack(spacing: ListBudgetTableLayout.amountColumnSpacing) {
                        if includesBudgetedColumn {
                            ListAmountText(amount: income.budgeted)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .accessibilityLabel(budgetedAccessibilityLabel)
                                .accessibilityIdentifier("listIncomeBudgeted.\(income.categoryId)")
                        }
                        Button {
                            onShowTransactions(income, income.month)
                        } label: {
                            ListAmountText(amount: income.received)
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
        .padding(.vertical, ListBudgetTableLayout.categoryRowVerticalPadding)
        .frame(minHeight: ListBudgetTableLayout.categoryRowMinimumHeight)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(Color(.systemBackground))
        .accessibilityIdentifier("listIncomeCategory.\(income.categoryId)")
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
            ListAmountText(amount: amount)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(budgetedAccessibilityLabel)
        .accessibilityIdentifier("listIncomeBudgeted.\(income.categoryId)")
    }

    private var budgetedAccessibilityLabel: String {
        "Budgeted for \(income.categoryName), \(budgetStore.displayBalance(income.budgeted))"
    }

    private var monthTransactionsLabel: String {
        "Transactions for \(income.categoryName) in \(MonthPicker.title(for: income.month)), received \(budgetStore.displayBalance(income.received))"
    }
}

private struct ListAmountText: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let amount: Int
    var isBalance = false

    var body: some View {
        Text(budgetStore.displayListBudgetCell(amount))
            .font(.footnote.weight(isBalance ? .semibold : .regular))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.35)
            .allowsTightening(!dynamicTypeSize.isAccessibilitySize)
            .foregroundStyle(foregroundColor)
            .animatedAmount(budgetStore.displayListBudgetCell(amount))
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
        switch ListBalanceTone(amount: amount, isMasked: budgetStore.hideBalances) {
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
        case .list:
            listStyle(.plain)
        case .clean, .detailed:
            self
        }
    }
}

private extension BudgetStore {
    @MainActor
    func displayListBudgetCell(_ cents: Int) -> String {
        hideBalances
            ? Self.hiddenBalanceText
            : CurrencyAmountFormat.symbolLessString(
                cents: cents,
                currencyCode: currencyCode
            )
    }
}
