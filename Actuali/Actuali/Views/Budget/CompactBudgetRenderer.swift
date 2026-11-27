import Combine
import SwiftUI

/// The summary and every group header are rounded cards. Where a pinned header
/// docks against the summary, the edge they share goes square so the two read
/// as one card (the summary draws the single divider between them).
enum CompactBudgetCard {
    static let cornerRadius: CGFloat = 12
    static let morph = Animation.easeOut(duration: 0.15)
    /// In light mode secondarySystemBackground is the same grey as the
    /// systemGroupedBackground behind the cards, which hides their corners,
    /// so light mode uses a step darker. Dark mode keeps its old fill.
    static let fill = UIColor { $0.userInterfaceStyle == .dark ? .secondarySystemBackground : .systemGray5 }

    static func shape(topSquare: Bool = false, bottomSquare: Bool = false) -> UnevenRoundedRectangle {
        let top = topSquare ? 0 : cornerRadius
        let bottom = bottomSquare ? 0 : cornerRadius
        return UnevenRoundedRectangle(
            topLeadingRadius: top,
            bottomLeadingRadius: bottom,
            bottomTrailingRadius: bottom,
            topTrailingRadius: top,
            style: .continuous
        )
    }
}

/// Finds the header touching the summary. Geometry changes update this tracker,
/// and only a change of touching header invalidates an observing view.
@MainActor
final class CompactDockTracker: ObservableObject {
    /// The id of the header touching the summary, if any.
    @Published private(set) var dockedID: String?
    private var summaryBottom: CGFloat?
    private var headerTops: [String: CGFloat] = [:]

    func setSummaryBottom(_ y: CGFloat) {
        summaryBottom = y
        publish()
    }

    func setHeaderTop(_ y: CGFloat, for id: String) {
        guard headerTops[id] != y else { return }
        headerTops[id] = y
        publish()
    }

    func removeHeader(_ id: String) {
        guard headerTops.removeValue(forKey: id) != nil else { return }
        publish()
    }

    private func publish() {
        // Touching: the header's top is near the summary's bottom edge.
        // ponytail: -4...12 accommodates the native List section-header inset.
        // Ceiling: a different runtime or list style may use a larger inset.
        // Upgrade path: measure the hosting inset directly if this diverges.
        let next = summaryBottom.flatMap { bottom in
            headerTops
                .filter { (-4...12).contains($0.value - bottom) }
                .min { (abs($0.value - bottom), $0.key) < (abs($1.value - bottom), $1.key) }?
                .key
        }
        if next != dockedID {
            dockedID = next
        }
    }
}

/// Re-renders only its own content when the docking changes. The tracker is
/// deliberately not observed by BudgetView: a docking change there would
/// rebuild the whole table on a scroll frame.
struct DockObserver<Content: View>: View {
    @ObservedObject var tracker: CompactDockTracker
    let content: (String?) -> Content

    init(_ tracker: CompactDockTracker, @ViewBuilder content: @escaping (String?) -> Content) {
        self.tracker = tracker
        self.content = content
    }

    var body: some View {
        content(tracker.dockedID)
    }
}

struct CompactBudgetSummary: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale

    let budget: BudgetMonth
    let showsSpent: Bool
    let showsBudgeted: Bool
    var isHeaderDocked = false

    private var overview: CompactBudgetOverview {
        CompactBudgetOverview(
            budget: budget,
            showsSpent: showsSpent,
            showsBudgeted: showsBudgeted,
            excludedFromSpentCategoryIds: budgetStore.excludedFromSpentCategoryIds,
            currentMonth: BudgetView.currentMonthString()
        )
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    if overview.leading.kind == .toBudget {
                        BudgetBufferCompactSummaryStat(
                            stat: overview.leading,
                            alignment: .leading
                        )
                    } else {
                        CompactOverviewStat(
                            stat: overview.leading,
                            isResult: false,
                            alignment: .leading
                        )
                    }
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
                    Group {
                        if overview.leading.kind == .toBudget {
                            BudgetBufferCompactSummaryStat(
                                stat: overview.leading,
                                alignment: .leading
                            )
                        } else {
                            CompactOverviewStat(
                                stat: overview.leading,
                                isResult: false,
                                alignment: .leading
                            )
                        }
                    }
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
        .background(
            Color(CompactBudgetCard.fill),
            in: CompactBudgetCard.shape(bottomSquare: isHeaderDocked)
        )
        .overlay(alignment: .bottom) {
            if isHeaderDocked {
                Divider()
            }
        }
        .animation(CompactBudgetCard.morph, value: isHeaderDocked)
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

private extension View {
    @ViewBuilder
    func balancePill(_ color: Color, isMasked: Bool, active: Bool) -> some View {
        if active {
            self
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(color.opacity(isMasked ? 0.08 : 0.14))
                }
        } else {
            self
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
        Text(budgetStore.displayBalance(stat.amount))
            .font(.footnote.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.35)
            .allowsTightening(!dynamicTypeSize.isAccessibilitySize)
            .foregroundStyle(resultColor)
            .animatedAmount(budgetStore.displayBalance(stat.amount))
            .balancePill(
                resultColor,
                isMasked: budgetStore.hideBalances,
                active: isResult
            )
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
    @State private var isLifted = false

    let name: String
    let isCollapsed: Bool
    var isHidden = false
    var onSetHidden: ((Bool) -> Void)?
    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?
    var onApplyTemplate: (() -> Void)?
    var onOverwriteTemplate: (() -> Void)?
    let totals: CategoryGroupTotals?
    let showsSpent: Bool
    let showsBudgeted: Bool
    let onToggleCollapse: () -> Void
    /// Docked against the summary: the top corners go square.
    var isConnectedToSummary = false
    var dockID = ""
    var dockTracker: CompactDockTracker?

    private var presentation: CompactBudgetGroupHeaderPresentation {
        CompactBudgetGroupHeaderPresentation(totals: totals, showsSpent: showsSpent, showsBudgeted: showsBudgeted)
    }

    /// Keep the same column geometry when totals are hidden so toggling the
    /// preference only changes the content, not the header's dimensions.
    private var columnsForLayout: [CompactBudgetGroupHeaderPresentation.Column] {
        guard totals == nil else { return presentation.columns }
        return CompactBudgetTableLayout(isTrackingBudget: false, showsSpent: showsSpent, showsBudgeted: showsBudgeted)
            .expenseColumns
            .map { .init(type: $0, amount: 0) }
    }

    private var menuActions: [ContextMenuHostAction] {
        ContextMenuHostAction.groupActions(
            isHidden: isHidden,
            onApplyTemplate: onApplyTemplate,
            onOverwriteTemplate: onOverwriteTemplate,
            onRename: onRename,
            onSetHidden: onSetHidden,
            onDelete: onDelete,
            locale: locale
        )
    }

    var body: some View {
        // Tap collapses; long-press lifts the whole row into a native context
        // menu, like the Clean header. A List section header can't present
        // SwiftUI's .contextMenu, so a UIKit overlay carries the menu.
        let actions = menuActions
        headerContent
            .foregroundStyle(.primary)
            .background(
                Color(CompactBudgetCard.fill),
                in: CompactBudgetCard.shape(topSquare: isConnectedToSummary)
            )
            .animation(CompactBudgetCard.morph, value: isConnectedToSummary)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
                dockTracker?.setHeaderTop($0, for: dockID)
            }
            .onDisappear {
                dockTracker?.removeHeader(dockID)
            }
            .opacity(isLifted ? 0 : isHidden ? 0.5 : 1)
            .overlay {
                ContextMenuHost(actions: actions, onTap: onToggleCollapse, onLift: { isLifted = $0 })
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("compactBudgetGroup.\(name)")
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(
                actions.isEmpty
                    ? String(localized: "Toggles the group's categories", bundle: .main, locale: locale)
                    : String(localized: "Tap to toggle the group's categories; touch and hold for options", bundle: .main, locale: locale)
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onToggleCollapse() }
            .accessibilityActions {
                ForEach(actions.indices, id: \.self) { index in
                    Button(actions[index].title, action: actions[index].handler)
                }
            }
            .listRowInsets(EdgeInsets())
    }

    private var headerContent: some View {
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
            budgeted: showsBudgeted ? budgetStore.displayBalance(totals.budgeted) : nil,
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
    var onSetHidden: ((Bool) -> Void)?
    let showsSpent: Bool
    let showsBudgeted: Bool
    let showsProgressBars: Bool
    let showsStatusDots: Bool
    var onShowDetails: (CategoryBudget) -> Void = { _ in }
    var onEditBudget: (CategoryBudget) -> Void = { _ in }
    var onShowTransactions: (CategoryBudget, String?) -> Void = { _, _ in }
    var onMoveMoney: (CategoryBudget) -> Void = { _ in }
    /// Apply this category's own templates (GH #495); nil hides the item —
    /// callers gate it on the goalTemplatesEnabled flag.
    var onApplyTemplate: ((CategoryBudget) -> Void)?
    let onRename: (CategoryBudget) -> Void
    var onDelete: ((CategoryBudget) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if dynamicTypeSize.isAccessibilitySize {
                stackedContent
            } else {
                compactContent
            }
            if showsProgressBars, category.showsProgressBar {
                CategoryProgressBar(category: category)
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
            onMoveMoney: onMoveMoney,
            onApplyTemplate: onApplyTemplate,
            onRename: onRename,
            onDelete: onDelete
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
                if showsBudgeted {
                    Button {
                        onEditBudget(category)
                    } label: {
                        CompactAmountText(amount: category.budgeted)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(editBudgetAccessibilityLabel)
                }

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
            if showsBudgeted {
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
            }

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
    @State private var isLifted = false

    let name: String
    var isCollapsed = false
    var isHidden = false
    var onSetHidden: ((Bool) -> Void)?
    var onRename: (() -> Void)?
    let totalBudgeted: Int
    let totalReceived: Int
    let isTrackingBudget: Bool
    let showsSpent: Bool
    let showsBudgeted: Bool
    var onToggleCollapse: () -> Void = {}
    /// Docked against the summary: the top corners go square.
    var isConnectedToSummary = false
    var dockID = ""
    var dockTracker: CompactDockTracker?

    private var layout: CompactBudgetTableLayout {
        CompactBudgetTableLayout(isTrackingBudget: isTrackingBudget, showsSpent: showsSpent, showsBudgeted: showsBudgeted)
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

    private var menuActions: [ContextMenuHostAction] {
        ContextMenuHostAction.groupActions(
            isHidden: isHidden,
            onRename: onRename,
            onSetHidden: onSetHidden,
            locale: locale
        )
    }

    var body: some View {
        // Same native context menu as the expense group headers.
        let actions = menuActions
        headerContent
            .foregroundStyle(.primary)
            .background(
                Color(CompactBudgetCard.fill),
                in: CompactBudgetCard.shape(topSquare: isConnectedToSummary)
            )
            .animation(CompactBudgetCard.morph, value: isConnectedToSummary)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
                dockTracker?.setHeaderTop($0, for: dockID)
            }
            .onDisappear {
                dockTracker?.removeHeader(dockID)
            }
            .opacity(isLifted ? 0 : isHidden ? 0.5 : 1)
            .overlay {
                ContextMenuHost(actions: actions, onTap: onToggleCollapse, onLift: { isLifted = $0 })
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("compactIncomeSection")
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(
                actions.isEmpty
                    ? String(localized: "Toggles the income categories", bundle: .main, locale: locale)
                    : String(localized: "Tap to toggle the income categories; touch and hold for options", bundle: .main, locale: locale)
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onToggleCollapse() }
            .accessibilityActions {
                ForEach(actions.indices, id: \.self) { index in
                    Button(actions[index].title, action: actions[index].handler)
                }
            }
            .listRowInsets(EdgeInsets())
    }

    private var headerContent: some View {
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
        CompactBudgetAccessibility.incomeHeader(
            name: name,
            state: isCollapsed ? String(localized: "collapsed", bundle: .main, locale: locale) : String(localized: "expanded", bundle: .main, locale: locale),
            budgeted: layout.incomeColumns.contains(.budgeted) ? budgetStore.displayBalance(totalBudgeted) : nil,
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
    var onSetHidden: ((Bool) -> Void)?
    let isTrackingBudget: Bool
    let showsSpent: Bool
    let showsBudgeted: Bool
    var onEditBudget: (IncomeCategory) -> Void = { _ in }
    var onShowTransactions: (IncomeCategory, String?) -> Void = { _, _ in }
    var onDelete: (() -> Void)?

    private var layout: CompactBudgetTableLayout {
        CompactBudgetTableLayout(isTrackingBudget: isTrackingBudget, showsSpent: showsSpent, showsBudgeted: showsBudgeted)
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    nameButton
                    if layout.incomeColumns.contains(.budgeted) {
                        Button {
                            onEditBudget(income)
                        } label: {
                            stackedBudgetedAmount(label: CompactBudgetColumn.budgeted.label(locale: locale, bundle: .main), amount: income.budgeted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(editBudgetAccessibilityLabel)
                        .accessibilityIdentifier("compactIncomeBudgeted.\(income.categoryId)")
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
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete Category", systemImage: "trash")
                }
                .accessibilityIdentifier("categoryDelete.action")
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

    private func stackedBudgetedAmount(label: String, amount: Int) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            CompactAmountText(amount: amount)
        }
    }

    @ViewBuilder
    private func compactColumn(_ column: CompactBudgetColumn?) -> some View {
        switch column {
        case .budgeted:
            Button {
                onEditBudget(income)
            } label: {
                CompactAmountText(amount: income.budgeted)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(editBudgetAccessibilityLabel)
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

    private var editBudgetAccessibilityLabel: String {
        CompactBudgetAccessibility.editBudget(
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
    var balanceColor: Color?

    var body: some View {
        Text(budgetStore.displayBalance(amount))
            .font(.footnote.weight(isBalance ? .semibold : .regular))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.35)
            .allowsTightening(!dynamicTypeSize.isAccessibilitySize)
            .foregroundStyle(foregroundColor)
            .animatedAmount(budgetStore.displayBalance(amount))
            .balancePill(
                foregroundColor,
                isMasked: budgetStore.hideBalances,
                active: isBalance
            )
            .accessibilityLabel(budgetStore.displayBalance(amount))
    }

    private var foregroundColor: Color {
        guard isBalance else {
            return amount == 0 ? .secondary : .primary
        }
        if budgetStore.hideBalances {
            return .primary
        }
        if let balanceColor {
            return balanceColor
        }
        switch CompactBalanceTone(amount: amount, isMasked: budgetStore.hideBalances) {
        case .negative: return .red
        case .zero: return .secondary
        case .positive: return .green
        case .masked: return .primary
        }
    }
}
