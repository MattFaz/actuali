import SwiftUI

struct CompactBudgetSummary: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    let budget: BudgetMonth
    let showsSpent: Bool

    private var overview: CompactBudgetOverview {
        CompactBudgetOverview(
            budget: budget,
            showsSpent: showsSpent,
            currentMonth: BudgetView.currentMonthString()
        )
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    CompactOverviewStat(
                        stat: overview.leading,
                        isResult: overview.leading.kind == .toBudget,
                        alignment: .leading
                    )
                    ForEach(Array(overview.columns.enumerated()), id: \.offset) { _, stat in
                        HStack {
                                Text(stat.label(locale: locale, bundle: .main))
                                .foregroundStyle(.secondary)
                            Spacer()
                            CompactOverviewAmount(stat: stat, isResult: isResult(stat))
                        }
                    }
                }
            } else {
                HStack(spacing: 0) {
                    CompactOverviewStat(
                        stat: overview.leading,
                        isResult: overview.leading.kind == .toBudget,
                        alignment: .leading
                    )
                        .frame(
                            width: CompactBudgetTableLayout.titleColumnWidth,
                            alignment: .leading
                        )

                    HStack(spacing: CompactBudgetTableLayout.amountColumnSpacing) {
                        ForEach(Array(overview.columns.enumerated()), id: \.offset) { _, stat in
                            CompactOverviewStat(stat: stat, isResult: isResult(stat))
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
                ? "compactBudgetOverview.stacked"
                : "compactBudgetOverview"
        )
    }

    private func isResult(_ stat: CompactBudgetOverview.Stat) -> Bool {
        switch stat.kind {
        case .balance, .projected, .saved: true
        case .toBudget, .income, .budgeted, .spent: false
        }
    }
}

private struct CompactOverviewStat: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    let stat: CompactBudgetOverview.Stat
    let isResult: Bool
    var alignment: HorizontalAlignment = .trailing

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(stat.label(locale: locale, bundle: .main))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.65)
                .allowsTightening(!dynamicTypeSize.isAccessibilitySize)
                .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
            CompactOverviewAmount(stat: stat, isResult: isResult)
        }
    }
}

private struct CompactOverviewAmount: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    let stat: CompactBudgetOverview.Stat
    let isResult: Bool

    var body: some View {
        Text(budgetStore.displayBudgetCell(stat.amount))
            .font(.footnote.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.35)
            .allowsTightening(!dynamicTypeSize.isAccessibilitySize)
            .foregroundStyle(resultColor)
            .animatedAmount(budgetStore.displayBudgetCell(stat.amount))
            .accessibilityLabel(ReportStrings.format(
                "%@, %@",
                stat.label(locale: locale, bundle: .main),
                budgetStore.displayBalance(stat.amount),
                locale: locale,
                bundle: .main
            ))
    }

    private var resultColor: Color {
        guard isResult else { return .primary }
        switch CompactBalanceTone(amount: stat.amount, isMasked: budgetStore.hideBalances) {
        case .negative: return .red
        case .zero: return .secondary
        case .positive: return .green
        case .masked: return .primary
        }
    }
}

struct CompactBudgetGroupHeader: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    let name: String
    let isCollapsed: Bool
    var isHidden = false
    var onSetHidden: ((Bool) -> Void)? = nil
    let totals: CategoryGroupTotals?
    let showsSpent: Bool
    let onToggleCollapse: () -> Void

    private var presentation: CompactBudgetGroupHeaderPresentation {
        CompactBudgetGroupHeaderPresentation(totals: totals, showsSpent: showsSpent)
    }

    /// Keep the same column geometry when totals are hidden so toggling the
    /// preference only changes the content, not the header's dimensions.
    private var columnsForLayout: [CompactBudgetGroupHeaderPresentation.Column] {
        guard totals == nil else { return presentation.columns }
        return CompactBudgetTableLayout(isTrackingBudget: false, showsSpent: showsSpent)
            .expenseColumns
            .map { .init(type: $0, amount: 0) }
    }

    var body: some View {
        Group {
            if let onSetHidden {
                Menu {
                    Button {
                        onSetHidden(!isHidden)
                    } label: {
                        Label(
                            isHidden ? String(localized: "Show", bundle: .main, locale: locale) : String(localized: "Hide", bundle: .main, locale: locale),
                            systemImage: isHidden ? "eye" : "eye.slash"
                        )
                    }
                } label: {
                    headerContent
                } primaryAction: {
                    onToggleCollapse()
                }
            } else {
                Button(action: onToggleCollapse) {
                    headerContent
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("compactBudgetGroup.\(name)")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(
            onSetHidden == nil
                ? String(localized: "Toggles the group's categories", bundle: .main, locale: locale)
                : String(localized: "Tap to toggle the group's categories; touch and hold for options", bundle: .main, locale: locale)
        )
        .foregroundStyle(.primary)
        .background(Color(.secondarySystemBackground))
        .opacity(isHidden ? 0.5 : 1)
        .listRowInsets(EdgeInsets())
    }

    @ViewBuilder private var headerContent: some View {
        HStack(spacing: 0) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        title
                        ForEach(columnsForLayout, id: \.type) { column in
                            HStack {
                                Text(column.type.label(locale: locale, bundle: .main))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                CompactAmountText(
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
                                width: CompactBudgetTableLayout.titleColumnWidth,
                                alignment: .leading
                            )
                        HStack(spacing: CompactBudgetTableLayout.amountColumnSpacing) {
                            ForEach(columnsForLayout, id: \.type) { column in
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(column.type.label(locale: locale, bundle: .main))
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.65)
                                    CompactAmountText(
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
        let state = isCollapsed ? String(localized: "collapsed", bundle: .main, locale: locale) : String(localized: "expanded", bundle: .main, locale: locale)
        guard let totals else {
            return ReportStrings.format("%@, %@", name, state, locale: locale, bundle: .main)
        }
        return CompactBudgetAccessibility.groupHeader(
            name: name,
            state: state,
            budgeted: budgetStore.displayBalance(totals.budgeted),
            spent: showsSpent ? budgetStore.displayBalance(totals.spent) : nil,
            balance: budgetStore.displayBalance(totals.balance),
            locale: locale,
            bundle: .main
        )
    }
}

struct CompactCategoryBudgetRow: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    let category: CategoryBudget
    var isHidden = false
    var isDimmed = false
    var onSetHidden: ((Bool) -> Void)? = nil
    let showsSpent: Bool
    let showsProgressBars: Bool
    let showsStatusDots: Bool
    var onShowDetails: (CategoryBudget) -> Void = { _ in }
    var onEditBudget: (CategoryBudget) -> Void = { _ in }
    var onShowTransactions: (CategoryBudget, String?) -> Void = { _, _ in }
    var onMoveMoney: (CategoryBudget) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if dynamicTypeSize.isAccessibilitySize {
                stackedContent
            } else {
                compactContent
            }
            if showsProgressBars, category.showsProgressBar {
                CategoryProgressBar(
                    fraction: category.progressFraction,
                    state: category.progressState
                )
            }
        }
        .padding(.vertical, CompactBudgetTableLayout.categoryRowVerticalPadding)
        .frame(minHeight: CompactBudgetTableLayout.categoryRowMinimumHeight)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(Color(.systemBackground))
        .accessibilityIdentifier("compactBudgetCategory.\(category.categoryId)")
        .opacity(isDimmed ? 0.5 : 1)
        .modifier(CategoryRowContextMenu(
            category: category,
            isHidden: isHidden,
            onSetHidden: onSetHidden,
            onShowDetails: onShowDetails,
            onEditBudget: onEditBudget,
            onShowTransactions: onShowTransactions,
            onMoveMoney: onMoveMoney
        ))
    }

    private var compactContent: some View {
        HStack(spacing: 0) {
            detailButton
                .frame(
                    width: CompactBudgetTableLayout.titleColumnWidth,
                    alignment: .leading
                )

            HStack(spacing: CompactBudgetTableLayout.amountColumnSpacing) {
                Button {
                    onEditBudget(category)
                } label: {
                    CompactAmountText(amount: category.budgeted)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(editBudgetAccessibilityLabel)

                if showsSpent {
                    Button {
                        onShowTransactions(category, category.month)
                    } label: {
                        CompactAmountText(amount: category.spent)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(monthTransactionsLabel)
                }

                Button {
                    onMoveMoney(category)
                } label: {
                    CompactAmountText(
                        amount: category.available,
                        isBalance: true,
                        balanceColor: categoryBalanceColor
                    )
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .buttonStyle(.borderless)
                .disabled(category.available == 0)
                .accessibilityLabel(balanceActionLabel)
                .rolloverIndicator(category.carryoverEnabled, color: categoryBalanceColor)
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
                stackedAmount(
                    label: CompactBudgetColumn.budgeted.label(locale: locale, bundle: .main),
                    amount: category.budgeted
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(editBudgetAccessibilityLabel)

            if showsSpent {
                Button {
                    onShowTransactions(category, category.month)
                } label: {
                    stackedAmount(
                        label: CompactBudgetColumn.spent.label(locale: locale, bundle: .main),
                        amount: category.spent
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(monthTransactionsLabel)
            }

            Button {
                onMoveMoney(category)
            } label: {
                stackedAmount(
                    label: CompactBudgetColumn.balance.label(locale: locale, bundle: .main),
                    amount: category.available,
                    isBalance: true
                )
            }
            .buttonStyle(.plain)
            .disabled(category.available == 0)
            .accessibilityLabel(balanceActionLabel)
            .rolloverIndicator(category.carryoverEnabled, color: categoryBalanceColor)
        }
    }

    private var detailButton: some View {
        Button {
            onShowDetails(category)
        } label: {
            HStack(spacing: 6) {
                if showsStatusDots {
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
            CompactAmountText(
                amount: amount,
                isBalance: isBalance,
                balanceColor: isBalance ? categoryBalanceColor : nil
            )
        }
        .contentShape(Rectangle())
    }

    private var categoryBalanceColor: Color {
        balanceColor(
            category,
            goalsEnabled: budgetStore.goalTemplatesEnabled,
            zero: .secondary
        )
    }

    private var monthTransactionsLabel: String {
        CompactBudgetAccessibility.monthTransactions(
            category: category.categoryName,
            month: MonthPicker.title(for: category.month),
            amountLabel: String(localized: "spent", bundle: .main, locale: locale),
            amount: budgetStore.displayBalance(category.spent),
            locale: locale,
            bundle: .main
        )
    }

    private var editBudgetAccessibilityLabel: String {
        CompactBudgetAccessibility.editBudget(
            category: category.categoryName,
            amount: budgetStore.displayBalance(category.budgeted),
            locale: locale,
            bundle: .main
        )
    }

    private var detailAccessibilityLabel: String {
        CompactBudgetAccessibility.details(
            category: category.categoryName,
            status: showsStatusDots ? category.progressState.statusText(locale: locale, bundle: .main) : nil,
            locale: locale,
            bundle: .main
        )
    }

    private var balanceActionLabel: String {
        let tone = CompactBalanceTone(
            amount: category.available,
            isMasked: budgetStore.hideBalances
        )
        return CompactBudgetAccessibility.balanceAction(
            category: category.categoryName,
            isOverspent: category.isOverspent,
            balance: budgetStore.displayBalance(category.available),
            tone: CompactBudgetAccessibility.balanceStatus(tone, locale: locale, bundle: .main),
            locale: locale,
            bundle: .main
        )
    }
}

struct CompactIncomeGroupHeader: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    let name: String
    var isCollapsed = false
    var isHidden = false
    var onSetHidden: ((Bool) -> Void)? = nil
    let totalBudgeted: Int
    let totalReceived: Int
    let showsBudgeted: Bool
    let showsSpent: Bool
    var onToggleCollapse: () -> Void = {}

    private var layout: CompactBudgetTableLayout {
        CompactBudgetTableLayout(isTrackingBudget: showsBudgeted, showsSpent: showsSpent)
    }

    private var columns: [(CompactBudgetColumn, Int)] {
        layout.incomeColumns.compactMap { optionalColumn -> (CompactBudgetColumn, Int)? in
            guard let column = optionalColumn else { return nil }
            switch column {
            case .budgeted: return (column, totalBudgeted)
            case .received: return (column, totalReceived)
            case .spent, .balance: return nil
            }
        }
    }

    var body: some View {
        Group {
            if let onSetHidden {
                Menu {
                    Button {
                        onSetHidden(!isHidden)
                    } label: {
                        Label(
                            isHidden ? String(localized: "Show", bundle: .main, locale: locale) : String(localized: "Hide", bundle: .main, locale: locale),
                            systemImage: isHidden ? "eye" : "eye.slash"
                        )
                    }
                } label: {
                    headerContent
                } primaryAction: {
                    onToggleCollapse()
                }
            } else {
                Button(action: onToggleCollapse) {
                    headerContent
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("compactIncomeSection")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(
            onSetHidden == nil
                ? String(localized: "Toggles the income categories", bundle: .main, locale: locale)
                : String(localized: "Tap to toggle the income categories; touch and hold for options", bundle: .main, locale: locale)
        )
        .foregroundStyle(.primary)
        .background(Color(.secondarySystemBackground))
        .opacity(isHidden ? 0.5 : 1)
        .listRowInsets(EdgeInsets())
    }

    @ViewBuilder private var headerContent: some View {
        HStack(spacing: 0) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        title
                        ForEach(columns, id: \.0) { column, amount in
                            HStack {
                                Text(column.label(locale: locale, bundle: .main))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                CompactAmountText(amount: amount)
                            }
                        }
                    }
                } else {
                    HStack(spacing: 0) {
                        title
                            .frame(
                                width: CompactBudgetTableLayout.titleColumnWidth,
                                alignment: .leading
                            )
                        HStack(spacing: CompactBudgetTableLayout.amountColumnSpacing) {
                            ForEach(Array(layout.incomeColumns.enumerated()), id: \.offset) { _, column in
                                Group {
                                    if let column {
                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text(column.label(locale: locale, bundle: .main))
                                                .font(.caption2)
                                            CompactAmountText(amount: amount(for: column))
                                        }
                                    } else {
                                        Color.clear
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .layoutPriority(1)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
        return CompactBudgetAccessibility.incomeHeader(
            name: name,
            state: isCollapsed ? String(localized: "collapsed", bundle: .main, locale: locale) : String(localized: "expanded", bundle: .main, locale: locale),
            budgeted: showsBudgeted ? budgetStore.displayBalance(totalBudgeted) : nil,
            received: budgetStore.displayBalance(totalReceived),
            locale: locale,
            bundle: .main
        )
    }

    private func amount(for column: CompactBudgetColumn) -> Int {
        column == .budgeted ? totalBudgeted : totalReceived
    }
}

struct CompactIncomeCategoryRow: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    let income: IncomeCategory
    var isHidden = false
    var isDimmed = false
    var onSetHidden: ((Bool) -> Void)? = nil
    let showsBudgeted: Bool
    let showsSpent: Bool
    var onShowTransactions: (IncomeCategory, String?) -> Void = { _, _ in }

    private var layout: CompactBudgetTableLayout {
        CompactBudgetTableLayout(isTrackingBudget: showsBudgeted, showsSpent: showsSpent)
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    nameButton
                    if showsBudgeted {
                        stackedReadOnlyAmount(label: CompactBudgetColumn.budgeted.label(locale: locale, bundle: .main), amount: income.budgeted)
                    }
                    Button {
                        onShowTransactions(income, income.month)
                    } label: {
                        HStack {
                            Text(CompactBudgetColumn.received.label(locale: locale, bundle: .main))
                                .foregroundStyle(.secondary)
                            Spacer()
                            CompactAmountText(amount: income.received)
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
                            width: CompactBudgetTableLayout.titleColumnWidth,
                            alignment: .leading
                        )
                    HStack(spacing: CompactBudgetTableLayout.amountColumnSpacing) {
                        ForEach(Array(layout.incomeColumns.enumerated()), id: \.offset) { _, column in
                            compactColumn(column)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .layoutPriority(1)
                }
            }
        }
        .padding(.vertical, CompactBudgetTableLayout.categoryRowVerticalPadding)
        .frame(minHeight: CompactBudgetTableLayout.categoryRowMinimumHeight)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(Color(.systemBackground))
        .accessibilityIdentifier("compactIncomeCategory.\(income.categoryId)")
        .opacity(isDimmed ? 0.5 : 1)
        .contextMenu {
            if let onSetHidden {
                Button {
                    onSetHidden(!isHidden)
                } label: {
                    Label(isHidden ? String(localized: "Show", bundle: .main, locale: locale) : String(localized: "Hide", bundle: .main, locale: locale), systemImage: isHidden ? "eye" : "eye.slash")
                }
            }
        }
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
        .accessibilityLabel(ReportStrings.format(
            "All transactions for %@",
            income.categoryName,
            locale: locale,
            bundle: .main
        ))
    }

    private func stackedReadOnlyAmount(label: String, amount: Int) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            CompactAmountText(amount: amount)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(budgetedAccessibilityLabel)
        .accessibilityIdentifier("compactIncomeBudgeted.\(income.categoryId)")
    }

    @ViewBuilder
    private func compactColumn(_ column: CompactBudgetColumn?) -> some View {
        switch column {
        case .budgeted:
            CompactAmountText(amount: income.budgeted)
                .accessibilityLabel(budgetedAccessibilityLabel)
                .accessibilityIdentifier("compactIncomeBudgeted.\(income.categoryId)")
        case .received:
            Button {
                onShowTransactions(income, income.month)
            } label: {
                CompactAmountText(amount: income.received)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(monthTransactionsLabel)
        case .none, .spent, .balance:
            Color.clear
        }
    }

    private var budgetedAccessibilityLabel: String {
        CompactBudgetAccessibility.incomeBudgeted(
            category: income.categoryName,
            amount: budgetStore.displayBalance(income.budgeted),
            locale: locale,
            bundle: .main
        )
    }

    private var monthTransactionsLabel: String {
        CompactBudgetAccessibility.monthTransactions(
            category: income.categoryName,
            month: MonthPicker.title(for: income.month),
            amountLabel: CompactBudgetColumn.received.label(locale: locale, bundle: .main),
            amount: budgetStore.displayBalance(income.received),
            locale: locale,
            bundle: .main
        )
    }
}

private struct CompactAmountText: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let amount: Int
    var isBalance = false
    var balanceColor: Color? = nil

    var body: some View {
        Text(budgetStore.displayBudgetCell(amount))
            .font(.footnote.weight(isBalance ? .semibold : .regular))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.35)
            .allowsTightening(!dynamicTypeSize.isAccessibilitySize)
            .foregroundStyle(foregroundColor)
            .animatedAmount(budgetStore.displayBudgetCell(amount))
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
        if budgetStore.hideBalances { return .primary }
        if let balanceColor { return balanceColor }
        switch CompactBalanceTone(amount: amount, isMasked: budgetStore.hideBalances) {
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
        case .compact:
            listStyle(.plain)
        case .clean:
            self
        }
    }
}
