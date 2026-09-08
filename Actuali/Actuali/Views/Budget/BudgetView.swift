import SwiftUI

private let yearMonthFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM"
    return formatter
}()

enum BudgetCategoryAccessibility {
    static func details(category: String, locale: Locale, bundle: Bundle = .main) -> String {
        ReportStrings.format("Details for %@", category, locale: locale, bundle: bundle)
    }

    static func editBudget(category: String, locale: Locale, bundle: Bundle = .main) -> String {
        ReportStrings.format("Edit budgeted amount for %@", category, locale: locale, bundle: bundle)
    }

    static func monthTransactions(category: String, month: String, locale: Locale, bundle: Bundle = .main) -> String {
        ReportStrings.format("Transactions for %@ in %@", category, month, locale: locale, bundle: bundle)
    }

    static func balanceAction(category: String, isOverspent: Bool, locale: Locale, bundle: Bundle = .main) -> String {
        ReportStrings.format(
            isOverspent ? "Cover overspending for %@" : "Move money from %@",
            category,
            locale: locale,
            bundle: bundle
        )
    }

    static func visibility(isHidden: Bool, locale: Locale, bundle: Bundle = .main) -> String {
        ReportStrings.text(isHidden ? "Show" : "Hide", locale: locale, bundle: bundle)
    }

    static func contextMoveAction(isOverspent: Bool, locale: Locale, bundle: Bundle = .main) -> String {
        ReportStrings.text(isOverspent ? "Cover Overspending" : "Move Money", locale: locale, bundle: bundle)
    }

    static func contextVisibility(isHidden: Bool, locale: Locale, bundle: Bundle = .main) -> String {
        ReportStrings.text(isHidden ? "Show Category" : "Hide Category", locale: locale, bundle: bundle)
    }
}

/// Style-specific list metrics live behind one exhaustive switch so adding a
/// display style cannot silently inherit another style's spacing or background.
private struct BudgetListMetrics {
    let sectionSpacing: ListSectionSpacing
    let horizontalContentMargin: CGFloat
    let topContentMargin: CGFloat
    let showsTopFade: Bool

    init(style: BudgetDisplayStyle) {
        switch style {
        case .clean:
            sectionSpacing = .default
            horizontalContentMargin = 4
            topContentMargin = 20
            showsTopFade = true
        case .compact:
            sectionSpacing = .custom(0)
            horizontalContentMargin = 0
            topContentMargin = 0
            showsTopFade = false
        }
    }
}

extension BudgetStore {
    /// Plain grouped cell text using the budget currency's native precision.
    /// The table headers supply the currency context, leaving more room for
    /// category names than repeating the symbol in every cell.
    func displayBudgetCell(_ cents: Int) -> String {
        hideBalances
            ? Self.hiddenBalanceText
            : CurrencyAmountFormat.symbolLessString(
                cents: cents,
                currencyCode: currencyCode,
                wholeUnits: hideDecimalPlaces,
                numberFormat: numberFormat
            )
    }
}

struct BudgetView: View {
    nonisolated static let incomeGroupCollapseID = "__income_group__"

    /// IDs controlled by Expand/Collapse All for the budget currently shown.
    /// Kept pure so the income-group participation has non-UI test coverage.
    nonisolated static func displayedGroupIDs(
        groupIDs: [String],
        hasIncome: Bool
    ) -> Set<String> {
        var ids = Set(groupIDs)
        if hasIncome { ids.insert(incomeGroupCollapseID) }
        return ids
    }

    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    @State private var selectedMonth = currentMonthString()
    @State private var editingCategory: CategoryBudget?
    @State private var selectedCategory: CategoryBudget?
    @State private var transferContext: BudgetTransferContext?
    @State private var transactionsDestination: CategoryTransactionsDestination?
    @State private var newBudgetItem: NewBudgetItem?
    @State private var categoryFilter: BudgetCategoryFilter = .all
    @State private var templateResult: GoalTemplateResultAlert?
    @State private var isRunningTemplates = false

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.isWideLayout) private var isWideLayout

    /// Category details present as an inspector column beside the table in a
    /// wide window, and as the usual sheet everywhere else. Same gate as
    /// AccountsListView's split layout.
    private var usesInspector: Bool {
        horizontalSizeClass == .regular && isWideLayout
    }

    /// Comma-joined group ids the user has collapsed, PWA-style. Stored as a
    /// string because @AppStorage can't hold a Set directly.
    @AppStorage("collapsedBudgetGroups") private var collapsedGroupsStorage = ""

    private var collapsedGroups: Set<String> {
        Set(collapsedGroupsStorage.split(separator: ",").map(String.init))
    }

    private var listMetrics: BudgetListMetrics {
        BudgetListMetrics(style: budgetStore.budgetDisplayStyle)
    }

    private func toggleCollapsed(_ groupId: String) {
        var groups = collapsedGroups
        if !groups.insert(groupId).inserted {
            groups.remove(groupId)
        }
        collapsedGroupsStorage = groups.sorted().joined(separator: ",")
    }

    // Expand/collapse all touch only the displayed budget's groups; ids
    // remembered for other budget files stay put (GH #130).
    private func collapseAllGroups() {
        let displayedGroupIDs = Self.displayedGroupIDs(
            groupIDs: groupedCategories.map(\.id),
            hasIncome: budgetStore.currentBudgetMonth.map {
                !displayedIncomeCategories(in: $0).isEmpty
            } ?? false
        )
        let groups = collapsedGroups.union(displayedGroupIDs)
        collapsedGroupsStorage = groups.sorted().joined(separator: ",")
    }

    private func expandAllGroups() {
        let displayedGroupIDs = Self.displayedGroupIDs(
            groupIDs: groupedCategories.map(\.id),
            hasIncome: budgetStore.currentBudgetMonth.map {
                !displayedIncomeCategories(in: $0).isEmpty
            } ?? false
        )
        let groups = collapsedGroups.subtracting(displayedGroupIDs)
        collapsedGroupsStorage = groups.sorted().joined(separator: ",")
    }

    private var isCompact: Bool {
        budgetStore.budgetDisplayStyle == .compact
    }

    /// Shape for the "N uncategorized" link's background, matching the shape
    /// used elsewhere for each display style. The compact style keeps sharp
    /// corners since its rows sit edge-to-edge with no rounding.
    private var uncategorizedShape: AnyShape {
        switch budgetStore.budgetDisplayStyle {
        case .clean: AnyShape(RoundedRectangle(cornerRadius: 24))
        case .compact: AnyShape(Rectangle())
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let budget = budgetStore.currentBudgetMonth {
                    loadedBudgetContent(budget)
                } else if !budgetStore.isLoading {
                    if budgetStore.isConnected && budgetStore.currentBudgetId == nil {
                        ContentUnavailableView(
                            "Select a Budget",
                            systemImage: "chart.pie",
                            description: Text(ReportStrings.text("You're connected. Choose a budget in More → Connection & Data to load it here.", locale: locale, bundle: .main))
                        )
                    } else {
                        ContentUnavailableView(
                            "No Budget Loaded",
                            systemImage: "chart.pie",
                            description: Text(ReportStrings.text("Go to More → Connection & Data to connect to your Actual Budget server", locale: locale, bundle: .main))
                        )
                    }
                }
            }
            .navigationTitle("Budget")
            // The summary bar is pinned outside the List (GH #155), so it
            // can't move with an overscroll the way list content does. A
            // large title stretches on that overscroll and draws straight
            // over the card, and collapses on scroll-up, jolting it (GH
            // #253). Inline keeps the bar a fixed height; the month stepper
            // below already occupies the centre, and the tab bar says
            // "Budget" anyway.
            .navigationBarTitleDisplayMode(.inline)
            .budgetNavigationBarBackground(isCompact: isCompact)
            .toolbar { budgetToolbar }
            .onAppear {
                selectedMonth = budgetStore.lastViewedBudgetMonth ?? selectedMonth
            }
            .onChange(of: budgetStore.currentBudgetId) { _, _ in
                selectedMonth = budgetStore.lastViewedBudgetMonth ?? Self.currentMonthString()
            }
            .onChange(of: selectedMonth) { _, newMonth in
                budgetStore.lastViewedBudgetMonth = newMonth
                Task {
                    await budgetStore.fetchBudgetMonth(newMonth)
                }
            }
            // Hiding the strip takes its filter with it — otherwise the table
            // stays filtered with no visible control to clear it.
            .onChange(of: budgetStore.showBudgetCheckInStrip) { _, isShown in
                if !isShown { categoryFilter = .all }
            }
            .sheet(item: $editingCategory) { category in
                EditBudgetAmountSheet(category: category)
            }
            // Compact only — in a wide window the inspector below presents
            // the same selection instead. The conditional binding also hands
            // an open presentation over to the other style on a window resize.
            .sheet(item: usesInspector ? .constant(nil) : $selectedCategory) { category in
                CategoryBudgetDetailSheet(category: category)
            }
            .inspector(isPresented: Binding(
                get: { usesInspector && selectedCategory != nil },
                set: { if !$0 { selectedCategory = nil } }
            )) {
                if let category = selectedCategory {
                    // .id resets the editor's @State (name draft, history) when
                    // the selection moves to another category — unlike a sheet,
                    // the inspector stays mounted across selections, so without
                    // it the previous category's draft would linger.
                    // ponytail: `category` is the value captured at tap time, so
                    // amounts shown in Quick Assign can go stale if a sync lands
                    // while the column is open — same ceiling the sheet always
                    // had, just longer-lived. Upgrade path: re-resolve by
                    // categoryId+month from currentBudgetMonth at render.
                    CategoryBudgetDetailSheet(category: category)
                        .id(category.id)
                        .inspectorColumnWidth(min: 320, ideal: 380, max: 480)
                }
            }
            .sheet(item: $transferContext) { context in
                BudgetTransferSheet(context: context)
            }
            .sheet(item: $newBudgetItem) { item in
                switch item {
                case .category:
                    NewCategorySheet(groupId: firstSelectableGroupId ?? "")
                case .group:
                    NewCategoryGroupSheet()
                }
            }
            .navigationDestination(item: $transactionsDestination) { destination in
                CategoryTransactionsView(destination: destination)
            }
            .overlay {
                if budgetStore.isLoading {
                    ProgressView()
                }
            }
            .alert(item: $templateResult) { result in
                Alert(
                    title: Text(result.title),
                    message: Text(result.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
        .initialSyncBanner()
    }

    /// Outcome of a goal-template run, presented as an alert.
    struct GoalTemplateResultAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// One group's rows, extracted from the `List` so the body stays within
    /// the compiler's type-check budget.
    @ViewBuilder
    private func groupSection(_ group: CategoryGroupSection) -> some View {
        let isCollapsed = collapsedGroups.contains(group.id)
        switch budgetStore.budgetDisplayStyle {
        case .clean:
            // Clean style: the group name sits above the card as a section
            // header, like the App Store screenshots. The same collapse
            // control lives there so collapsing behaves identically in both
            // styles.
            Section {
                if !isCollapsed {
                    ForEach(group.categories) { category in
                        CleanCategoryBudgetRow(
                            category: category,
                            isHidden: category.hidden,
                            isDimmed: category.isEffectivelyHidden,
                            onSetHidden: {
                                setCategoryHidden(category.categoryId, hidden: $0)
                            },
                            onShowDetails: { selectedCategory = $0 },
                            onEditBudget: { editingCategory = $0 },
                            // Name shows all time, Spent shows
                            // the displayed month (GH #56).
                            onShowTransactions: showTransactions,
                            onMoveMoney: moveMoney
                        )
                    }
                }
            } header: {
                BudgetGroupHeader(
                    name: group.name,
                    isCollapsed: isCollapsed,
                    isHidden: group.isHidden,
                    onSetHidden: {
                        setCategoryGroupHidden(group.id, hidden: $0)
                    },
                    onToggleCollapse: { toggleCollapsed(group.id) }
                )
                .textCase(nil)
            }
        case .compact:
            Section {
                if !isCollapsed {
                    ForEach(group.categories) { category in
                        CompactCategoryBudgetRow(
                            category: category,
                            isHidden: category.hidden,
                            isDimmed: category.isEffectivelyHidden,
                            onSetHidden: {
                                setCategoryHidden(category.categoryId, hidden: $0)
                            },
                            showsSpent: budgetStore.showCompactSpentColumn,
                            showsProgressBars: budgetStore.showBudgetProgressBars,
                            showsStatusDots: budgetStore.showCategoryStatusDots,
                            onShowDetails: { selectedCategory = $0 },
                            onEditBudget: { editingCategory = $0 },
                            onShowTransactions: showTransactions,
                            onMoveMoney: moveMoney
                        )
                    }
                }
            } header: {
                CompactBudgetGroupHeader(
                    name: group.name,
                    isCollapsed: isCollapsed,
                    isHidden: group.isHidden,
                    onSetHidden: {
                        setCategoryGroupHidden(group.id, hidden: $0)
                    },
                    totals: budgetStore.showGroupTotals ? group.totals : nil,
                    showsSpent: budgetStore.showCompactSpentColumn,
                    onToggleCollapse: { toggleCollapsed(group.id) }
                )
            }
        }
    }

    /// The income group drawn at the bottom of the table, extracted from the
    /// `List` so the body stays within the compiler's type-check budget.
    @ViewBuilder
    private func incomeSection(_ budget: BudgetMonth) -> some View {
        let isCollapsed = collapsedGroups.contains(Self.incomeGroupCollapseID)
        let group = budgetStore.categoryGroups.first(where: \.isIncome)
        let categories = displayedIncomeCategories(in: budget)
        let rawName = group?.name ?? categories.first?.groupName ?? "Income"
        let name = rawName == "Income"
            ? ReportStrings.text("Income", locale: locale, bundle: .main)
            : rawName
        let onSetHidden = group.flatMap { group -> ((Bool) -> Void)? in
            group.hidden ? { setCategoryGroupHidden(group.id, hidden: $0) } : nil
        }
        switch budgetStore.budgetDisplayStyle {
        case .clean:
            Section {
                if !isCollapsed {
                    ForEach(categories) { income in
                        IncomeCategoryRow(
                            income: income,
                            isHidden: income.hidden,
                            isDimmed: income.isEffectivelyHidden,
                            onSetHidden: {
                                setCategoryHidden(income.categoryId, hidden: $0)
                            },
                            showsBudgeted: budget.toBudget == nil,
                            onShowTransactions: showTransactions
                        )
                    }
                }
            } header: {
                // The Income group can only be unhidden, never hidden:
                // hiding it would drop the app's only income total
                // from the budget table entirely. `onSetHidden` is passed
                // only when the group is already hidden (e.g. leftover
                // state from before this restriction existed). GH #130's
                // collapse control still applies.
                BudgetGroupHeader(
                    name: name,
                    isCollapsed: isCollapsed,
                    isHidden: group?.hidden == true,
                    onSetHidden: onSetHidden,
                    receivedTotal: budget.totalIncome,
                    onToggleCollapse: {
                        toggleCollapsed(Self.incomeGroupCollapseID)
                    }
                )
                .textCase(nil)
            }
        case .compact:
            Section {
                if !isCollapsed {
                    ForEach(categories) { income in
                        CompactIncomeCategoryRow(
                            income: income,
                            isHidden: income.hidden,
                            isDimmed: income.isEffectivelyHidden,
                            onSetHidden: {
                                setCategoryHidden(income.categoryId, hidden: $0)
                            },
                            showsBudgeted: budget.isTrackingBudget,
                            showsSpent: budgetStore.showCompactSpentColumn,
                            onShowTransactions: showTransactions
                        )
                    }
                }
            } header: {
                CompactIncomeGroupHeader(
                    name: name,
                    isCollapsed: isCollapsed,
                    isHidden: group?.hidden == true,
                    onSetHidden: onSetHidden,
                    totalBudgeted: budget.totalBudgetedIncome,
                    totalReceived: budget.totalIncome,
                    showsBudgeted: budget.isTrackingBudget,
                    showsSpent: budgetStore.showCompactSpentColumn,
                    onToggleCollapse: {
                        toggleCollapsed(Self.incomeGroupCollapseID)
                    }
                )
            }
        }
    }

    /// The screen's toolbar, extracted from `body` so the whole screen stays
    /// within the compiler's type-check budget.
    @ToolbarContentBuilder
    private var budgetToolbar: some ToolbarContent {
        // Both arrows flank the month in the center, so nothing sits in the
        // leading "back button" position where the previous-month chevron
        // used to be mistaken for one (it steps the month, not the
        // navigation stack).
        ToolbarItem(placement: .principal) {
            // UIKit centers a title view only while it stays under ~140pt
            // next to these two trailing buttons; one point over and it
            // left-aligns the whole stepper against the leading edge instead.
            // That cliff has been hit twice — GH #234, then again by #319
            // padding both chevrons out to 44pt wide (44 + 44 + a 78pt
            // "Aug 2026" = 166). So the width is the budget: the touch target
            // grows downward to 44pt and stays 30pt wide, giving 138 total.
            // `.frame(maxWidth: .infinity)` can't buy centering back — the
            // title view is sized to fit its content, so the frame has no
            // extra width to center in.
            //
            // ponytail: 138 of ~140 is all the headroom there is, and the slot
            // shrinks as the trailing buttons scale, so raised text sizes still
            // left-align (measured at XXXL). Anything that needs a bigger
            // stepper — a third trailing button, unabbreviated months, real
            // Dynamic Type support — has to leave the bar for a pinned header
            // row above the summary card, where centering is real layout.
            HStack(spacing: 0) {
                Button {
                    selectedMonth = Self.shiftMonth(selectedMonth, by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 30, height: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Previous month")

                MonthPicker(selectedMonth: $selectedMonth)

                Button {
                    selectedMonth = Self.shiftMonth(selectedMonth, by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 30, height: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Next month")
            }
        }
        // Creation, unlike everything in the options menu, changes the budget
        // rather than the view of it — so it gets its own button (GH #284).
        // Nothing to add to until a budget is open.
        if budgetStore.currentBudgetMonth != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        newBudgetItem = .category
                    } label: {
                        Label("New Category", systemImage: "tag")
                    }
                    // A category needs a group to live in.
                    .disabled(firstSelectableGroupId == nil)
                    Button {
                        newBudgetItem = .group
                    } label: {
                        Label("New Group", systemImage: "folder")
                    }
                    .accessibilityLabel("New Category Group")
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add")
                .accessibilityHint("Create a category or category group")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            // Every "how should this look" control lives here (GH #157).
            // Whole-table expand/collapse is a menu rather than a long-press
            // on the group headers: SwiftUI context menus don't fire inside
            // the clean style's section headers (GH #130).
            // The isolated method references can't be inferred as optional
            // closures under Swift 6, so wrap them.
            let hasBudget = budgetStore.currentBudgetMonth != nil
            BudgetOptionsMenu(
                expandAllGroups: hasBudget ? { expandAllGroups() } : nil,
                collapseAllGroups: hasBudget ? { collapseAllGroups() } : nil,
                onTemplateAction: hasBudget && budgetStore.goalTemplatesEnabled
                    ? { runTemplates($0) } : nil
            )
        }
    }

    /// Run the month's template action and surface the outcome — the web
    /// shows these as toast notifications; an alert is the iOS equivalent.
    private func runTemplates(_ action: BudgetStore.GoalTemplateAction) {
        guard !isRunningTemplates else { return }
        isRunningTemplates = true
        Task {
            let outcome = await budgetStore.runGoalTemplates(month: selectedMonth, action: action)
            isRunningTemplates = false
            switch outcome {
            case .applied(let count):
                templateResult = .init(
                    title: ReportStrings.text("Templates Applied", locale: locale, bundle: .main),
                    message: String(localized: "Successfully applied templates to \(count) categories.", bundle: .main, locale: locale))
            case .upToDate:
                templateResult = .init(
                    title: ReportStrings.text("Templates Applied", locale: locale, bundle: .main),
                    message: ReportStrings.text("All templates are up to date.", locale: locale, bundle: .main))
            case .checkPassed:
                templateResult = .init(
                    title: ReportStrings.text("Check Passed", locale: locale, bundle: .main),
                    message: ReportStrings.text("All templates passed the check.", locale: locale, bundle: .main))
            case .errors(let errors):
                templateResult = .init(
                    title: ReportStrings.text("Template Errors", locale: locale, bundle: .main),
                    message: errors.joined(separator: "\n\n"))
            case .failed(let message):
                templateResult = .init(
                    title: ReportStrings.text("Template Error", locale: locale, bundle: .main),
                    message: message)
            }
        }
    }

    /// The pinned summary plus the scrolling budget table, shown once a
    /// budget month has loaded. Extracted from `body` so the whole screen
    /// stays within the compiler's type-check budget.
    @ViewBuilder
    private func loadedBudgetContent(_ budget: BudgetMonth) -> some View {
        VStack(spacing: 0) {
            if isCompact, budgetStore.showBudgetCheckInStrip {
                BudgetCheckInStrip(
                    budget: budget,
                    selection: $categoryFilter
                )
                .padding(.bottom, 8)
            }

            // Keep the summary above the List so it stays pinned while the
            // table scrolls (GH #155).
            if !isCompact
                || budgetStore.showCompactBudgetOverview {
                Group {
                    switch budgetStore.budgetDisplayStyle {
                    case .clean:
                        CleanBudgetSummary(budget: budget)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 24)
                                    .fill(Color(.secondarySystemGroupedBackground))
                            )
                    case .compact:
                        CompactBudgetSummary(
                            budget: budget,
                            showsSpent: budgetStore.showCompactSpentColumn
                        )
                    }
                }
                .padding(.horizontal, isCompact ? 0 : 4)
                .padding(.vertical, isCompact ? 0 : 8)
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
            }

            // The strip filters categories, so it can't express uncategorized
            // transactions — and the check-in card it replaced held the only
            // in-app route to that list (otherwise reachable only from a
            // notification tap).
            if budgetStore.uncategorizedCount > 0 {
                NavigationLink {
                    UncategorizedTransactionsView()
                } label: {
                    HStack {
                        Label(
                            "\(budgetStore.uncategorizedCount) uncategorized",
                            systemImage: "questionmark.circle.fill"
                        )
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                    // Reads as a full-width row like the List section it used
                    // to live in (GH #29 / #305), not a stray line of text.
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color(isCompact ? .systemBackground : .secondarySystemGroupedBackground),
                        in: uncategorizedShape
                    )
                }
                .accessibilityIdentifier("budgetUncategorized")
                .padding(.horizontal, isCompact ? 0 : 4)
                .padding(.bottom, 8)
            }

            if !isCompact, budgetStore.showBudgetCheckInStrip {
                BudgetCheckInStrip(
                    budget: budget,
                    selection: $categoryFilter
                )
                .padding(.bottom, 8)
            }

            List {
                if categoryFilter != .all, groupedCategories.isEmpty {
                    ContentUnavailableView {
                        Label("No Matching Categories", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("Try another category filter.")
                    } actions: {
                        Button("Show All Categories") {
                            categoryFilter = .all
                        }
                    }
                }

                ForEach(groupedCategories, id: \.id) { group in
                    groupSection(group)
                }

                // Income group last, matching the bottom of the web UI's
                // budget table.
                if categoryFilter == .all, !displayedIncomeCategories(in: budget).isEmpty {
                    incomeSection(budget)
                }
            }
            // Collapse state lives in @AppStorage, and a write to that lands
            // outside any withAnimation transaction — so the rows have to be
            // animated from here, off the stored value, rather than at the
            // call site.
            .animation(AppAnimation.disclosure, value: collapsedGroupsStorage)
            .listSectionSpacing(listMetrics.sectionSpacing)
            .contentMargins(
                .horizontal,
                listMetrics.horizontalContentMargin,
                for: .scrollContent
            )
            // Pull-to-refresh belongs to the table alone. Attached to the
            // container instead, SwiftUI also wires it to the check-in
            // strip's horizontal ScrollView, so dragging the chips down
            // fired a sync.
            .refreshable {
                await budgetStore.sync()
            }
            // The rest of the gap under the pinned summary — this part
            // scrolls away with the content, leaving the 8 pt gutter above.
            // Together they sit a notch wider than the spacing between the
            // group sections, so the summary reads as its own bar rather than
            // a first group (GH #165).
            .contentMargins(
                .top,
                listMetrics.topContentMargin,
                for: .scrollContent
            )
            .budgetListStyle(for: budgetStore.budgetDisplayStyle)
            // Let short rows (group headers) sit below the stock 44 pt
            // minimum; tap targets stay fine because the whole row is the
            // button.
            .environment(\.defaultMinListRowHeight, 32)
            // Rows leaving the table used to be chopped off flat against the
            // gutter under the summary, a hard grey line across mid-row. Fade
            // them into it instead. The List's top content margin above is
            // deeper than this fade, so at rest it covers empty background and
            // nothing on screen looks washed out.
            .overlay(alignment: .top) {
                if listMetrics.showsTopFade {
                    LinearGradient(
                        colors: [
                            Color(.systemGroupedBackground),
                            Color(.systemGroupedBackground).opacity(0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 12)
                    .allowsHitTesting(false)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard abs(dx) > abs(dy) * 1.5, abs(dx) > 60 else { return }
                        if dx > 0 {
                            selectedMonth = Self.shiftMonth(selectedMonth, by: -1)
                        } else {
                            selectedMonth = Self.shiftMonth(selectedMonth, by: 1)
                        }
                    }
            )
        }
        // The budget table is a fixed grid of narrow amount columns;
        // stretched to iPad width it becomes a category name and its numbers
        // separated by a foot of nothing.
        .readableWidth()
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
    /// Open the move-money sheet for a tapped balance (GH #128): cover
    /// overspending when red, move the surplus when green. The month is
    /// captured alongside so the picker lists its sibling categories.
    private func moveMoney(_ category: CategoryBudget) {
        guard let budget = budgetStore.currentBudgetMonth else { return }
        transferContext = BudgetTransferContext(category: category, budget: budget)
    }
    
    /// The group a new category starts out filed under: the first one the
    /// table would draw. Nil when the budget has no group to file it in.
    private var firstSelectableGroupId: String? {
        let visible = budgetStore.categoryGroups.filter { !$0.hidden }
        return visible.min { $0.sortOrder < $1.sortOrder }?.id
    }

    private func displayedIncomeCategories(in budget: BudgetMonth) -> [IncomeCategory] {
        budgetStore.showHiddenCategories ? budget.allIncomeCategories : budget.incomeCategories
    }

    private func setCategoryHidden(_ id: String, hidden: Bool) {
        Task {
            do {
                try await budgetStore.setCategoryHidden(
                    id: id,
                    hidden: hidden,
                    month: selectedMonth
                )
            } catch {
                budgetStore.error = error.localizedDescription
            }
        }
    }

    private func setCategoryGroupHidden(_ id: String, hidden: Bool) {
        Task {
            do {
                try await budgetStore.setCategoryGroupHidden(
                    id: id,
                    hidden: hidden,
                    month: selectedMonth
                )
            } catch {
                budgetStore.error = error.localizedDescription
            }
        }
    }

    /// Push the category's transactions: month narrows to one "yyyy-MM",
    /// nil means all time (GH #56).
    private func showTransactions(_ category: CategoryBudget, month: String?) {
        transactionsDestination = CategoryTransactionsDestination(
            categoryId: category.categoryId,
            categoryName: category.categoryName,
            month: month
        )
    }

    private func showTransactions(_ income: IncomeCategory, month: String?) {
        transactionsDestination = CategoryTransactionsDestination(
            categoryId: income.categoryId,
            categoryName: income.categoryName,
            month: month
        )
    }

    struct CategoryGroupSection {
        let id: String
        let name: String
        let isHidden: Bool
        /// The rows to draw, after "Hide Spent Categories" filtering.
        let categories: [CategoryBudget]
        /// Totals over the group's non-hidden category list.
        let totals: CategoryGroupTotals
    }

    var groupedCategories: [CategoryGroupSection] {
        guard let budget = budgetStore.currentBudgetMonth else { return [] }
        let categories = budgetStore.showHiddenCategories
            ? budget.allCategoryBudgets
            : budget.categoryBudgets
        let byGroup = Dictionary(grouping: categories, by: { $0.groupId })
        var sections = byGroup
            .compactMap { groupId, items -> (Double, CategoryGroupSection)? in
                guard let first = items.first else { return nil }
                // An explicit filter is its own visibility rule: "Not Funded"
                // must still match zero-available categories even when the
                // Hide Spent Categories setting would drop them from "All".
                let base = categoryFilter == .all
                    ? budgetStore.visibleCategoryBudgets(items)
                    : items.filter(categoryFilter.includes)
                let visible = base
                    .sorted { $0.categorySortOrder < $1.categorySortOrder }
                // A group whose rows are all hidden drops out entirely rather
                // than leaving a header stranded over an empty card.
                guard !visible.isEmpty else { return nil }
                return (
                    first.groupSortOrder,
                    CategoryGroupSection(
                        id: groupId,
                        name: first.groupName,
                        isHidden: first.groupHidden,
                        categories: visible,
                        totals: CategoryGroupTotals(
                            (categoryFilter == .all ? items : visible)
                                .filter { !$0.isEffectivelyHidden }
                        )
                    )
                )
            }
        // A group you just made has no categories, so the month's rows above
        // can't know about it. Draw it anyway — otherwise creating a group
        // looks like it did nothing (GH #284). Income groups stay out: this
        // list is the expense table, and income has its own section below,
        // which likewise only appears once it has categories.
        // Empty placeholders only belong in the unfiltered table: a filter
        // that matches nothing should show the empty state, not bare headers.
        sections += budgetStore.categoryGroups
            .filter {
                categoryFilter == .all && !$0.isIncome
                    && (budgetStore.showHiddenCategories || !$0.hidden)
                    && $0.categories.isEmpty
            }
            .map { group -> (Double, CategoryGroupSection) in
                (
                    group.sortOrder,
                    CategoryGroupSection(
                        id: group.id,
                        name: group.name,
                        isHidden: group.hidden,
                        categories: [],
                        totals: CategoryGroupTotals([])
                    )
                )
            }

        return sections
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }

    static func currentMonthString() -> String {
        yearMonthFormatter.string(from: Date())
    }

    static func shiftMonth(_ month: String, by offset: Int) -> String {
        BudgetStore.shiftBudgetMonth(month, by: offset) ?? month
    }
}

private extension View {
    @ViewBuilder
    func budgetNavigationBarBackground(
        isCompact: Bool
    ) -> some View {
        if isCompact {
            self
                .toolbarBackground(Color(.secondarySystemBackground), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        } else {
            self
        }
    }
}

/// A name that always occupies two lines' height, so short and wrapping
/// names produce equal-height rows and the amount columns line up (GH
/// #252). A hidden copy reserves the space and the visible copy centers
/// within it — `reservesSpace` alone pins the text to the top.
private struct TwoLineName: View {
    let text: String
    let font: Font
    var minimumScaleFactor: CGFloat = 1

    var body: some View {
        ZStack {
            Text(text)
                .font(font)
                .lineLimit(2, reservesSpace: true)
                .minimumScaleFactor(minimumScaleFactor)
                .hidden()

            Text(text)
                .font(font)
                .lineLimit(2)
                .minimumScaleFactor(minimumScaleFactor)
        }
    }
}

/// Status filters stay visible above the category list, so checking the
/// month never requires opening a menu or scrolling past a large card.
struct BudgetCheckInStrip: View {
    let budget: BudgetMonth
    @Binding var selection: BudgetCategoryFilter
    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(BudgetCategoryFilter.allCases) { filter in
                    Button {
                        selection = filter
                    } label: {
                        Text(filter.title(
                            count: count(for: filter),
                            isTrackingBudget: budget.isTrackingBudget,
                            locale: locale
                        ))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selection == filter ? Color.white : Color.primary)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 40)
                            .background {
                                Capsule()
                                    .fill(selection == filter
                                        ? Color.accentColor
                                        : Color(.secondarySystemGroupedBackground))
                            }
                            .overlay {
                                if selection != filter {
                                    Capsule()
                                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(ReportStrings.format("Show %@ categories", filter.title(
                        count: count(for: filter),
                        isTrackingBudget: budget.isTrackingBudget,
                        locale: locale
                    ), locale: locale, bundle: .main))
                    .accessibilityIdentifier("budgetFilter-\(filter.rawValue)")
                    .accessibilityAddTraits(selection == filter ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, 4, for: .scrollContent)
    }

    private func count(for filter: BudgetCategoryFilter) -> Int {
        budget.categoryBudgets.count(where: filter.includes)
    }
}

extension BudgetCategoryFilter {
    func title(
        count: Int,
        isTrackingBudget: Bool,
        locale: Locale = .autoupdatingCurrent,
        bundle: Bundle = .main
    ) -> String {
        let key: String.LocalizationValue
        switch self {
        case .all: key = String.LocalizationValue("budget.filter.all \(count)")
        case .needsAttention: key = String.LocalizationValue("budget.filter.needsAttention \(count)")
        case .overspent where isTrackingBudget: key = String.LocalizationValue("budget.filter.overBudget \(count)")
        case .overspent: key = String.LocalizationValue("budget.filter.overspent \(count)")
        case .unassigned where isTrackingBudget: key = String.LocalizationValue("budget.filter.noBudget \(count)")
        case .unassigned: key = String.LocalizationValue("budget.filter.notFunded \(count)")
        case .approachingLimit where isTrackingBudget: key = String.LocalizationValue("budget.filter.nearBudget \(count)")
        case .approachingLimit: key = String.LocalizationValue("budget.filter.almostSpent \(count)")
        case .onTrack where isTrackingBudget: key = String.LocalizationValue("budget.filter.withinBudget \(count)")
        case .onTrack: key = String.LocalizationValue("budget.filter.onTrack \(count)")
        }
        return String(localized: LocalizedStringResource(key, locale: locale, bundle: bundle))
    }
}
/// Clean-style category row, matching the App Store screenshots: name and a
/// large Available amount up top, the progress bar beneath, then tappable
/// Budgeted/Spent captions.
struct CleanCategoryBudgetRow: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    let category: CategoryBudget
    var isHidden = false
    var isDimmed = false
    var onSetHidden: ((Bool) -> Void)?
    var onShowDetails: (CategoryBudget) -> Void = { _ in }
    var onEditBudget: (CategoryBudget) -> Void = { _ in }
    /// Push the category's transactions: month narrows to one "yyyy-MM",
    /// nil means all time (GH #56).
    var onShowTransactions: (CategoryBudget, String?) -> Void = { _, _ in }
    /// Open the move-money sheet for this category's balance (GH #128).
    var onMoveMoney: (CategoryBudget) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    onShowDetails(category)
                } label: {
                    HStack(spacing: 6) {
                        if budgetStore.showCategoryStatusDots {
                            CompactCategoryStatusDot(state: category.progressState)
                        }
                        Text(category.categoryName)
                            .font(.body)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(BudgetCategoryAccessibility.details(category: category.categoryName, locale: locale))
                Spacer()
                // A zero balance has nothing to move and nothing to cover, so
                // it stays a plain label.
                Button {
                    onMoveMoney(category)
                } label: {
                    Text(budgetStore.displayBalance(category.available))
                        .foregroundColor(balanceTint)
                }
                .buttonStyle(.borderless)
                .disabled(category.available == 0)
                .accessibilityLabel(BudgetCategoryAccessibility.balanceAction(
                    category: category.categoryName,
                    isOverspent: category.isOverspent,
                    locale: locale
                ))
                .rolloverIndicator(category.carryoverEnabled, color: balanceTint)
            }
            if budgetStore.showBudgetProgressBars, category.showsProgressBar {
                CategoryProgressBar(
                    fraction: category.progressFraction,
                    state: category.progressState
                )
            }
            HStack {
                Button {
                    onEditBudget(category)
                } label: {
                    HStack(spacing: 4) {
                        Text("Budgeted: \(budgetStore.displayBalance(category.budgeted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: "pencil")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(BudgetCategoryAccessibility.editBudget(category: category.categoryName, locale: locale))
                Spacer()
                Button {
                    onShowTransactions(category, category.month)
                } label: {
                    HStack(spacing: 4) {
                        // Green + signed so a deposit-only category doesn't
                        // read as spending (GH #102).
                        Text("Spent: \(budgetStore.displaySpentCaption(category.spent))")
                            .font(.caption)
                            .foregroundStyle(category.spent > 0
                                ? AnyShapeStyle(Color.green)
                                : AnyShapeStyle(.secondary))
                        Image(systemName: "list.bullet")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(BudgetCategoryAccessibility.monthTransactions(
                    category: category.categoryName,
                    month: MonthPicker.title(for: category.month, locale: locale),
                    locale: locale
                ))
            }
        }
        .opacity(isDimmed ? 0.5 : 1)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let onSetHidden {
                Button {
                    onSetHidden(!isHidden)
                } label: {
                    Label(BudgetCategoryAccessibility.visibility(isHidden: isHidden, locale: locale), systemImage: isHidden ? "eye" : "eye.slash")
                }
                .tint(isHidden ? .accentColor : .secondary)
            }
        }
        .padding(.vertical, 2)
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

    private var balanceTint: Color {
        balanceColor(category, goalsEnabled: budgetStore.goalTemplatesEnabled, zero: .green)
    }
}

/// Shared long-press/right-click menu for all category row styles — the same
/// actions as the row's tappable cells plus the hide/show swipe action.
struct CategoryRowContextMenu: ViewModifier {
    @Environment(\.locale) private var locale
    let category: CategoryBudget
    let isHidden: Bool
    let onSetHidden: ((Bool) -> Void)?
    let onShowDetails: (CategoryBudget) -> Void
    let onEditBudget: (CategoryBudget) -> Void
    let onShowTransactions: (CategoryBudget, String?) -> Void
    let onMoveMoney: (CategoryBudget) -> Void

    func body(content: Content) -> some View {
        content.contextMenu {
            Button { onShowDetails(category) } label: {
                Label("Category Details", systemImage: "info.circle")
            }
            Button { onEditBudget(category) } label: {
                Label("Edit Budgeted Amount", systemImage: "pencil")
            }
            Button { onShowTransactions(category, category.month) } label: {
                Label("Transactions This Month", systemImage: "list.bullet")
            }
            Button { onShowTransactions(category, nil) } label: {
                Label("All Transactions", systemImage: "list.bullet.rectangle")
            }
            // Zero balance: nothing to move, nothing to cover — same rule as
            // the balance pill.
            if category.available != 0 {
                Button { onMoveMoney(category) } label: {
                      Label(BudgetCategoryAccessibility.contextMoveAction(isOverspent: category.isOverspent, locale: locale),
                          systemImage: "arrow.left.arrow.right")
                }
            }
            if let onSetHidden {
                Button { onSetHidden(!isHidden) } label: {
                    Label(BudgetCategoryAccessibility.contextVisibility(isHidden: isHidden, locale: locale),
                          systemImage: isHidden ? "eye" : "eye.slash")
                }
            }
        }
    }
}

/// Balance color with goal awareness — port of the web's
/// `makeBalanceAmountStyle`: negative is always red; with goal templates
/// enabled and a goal on the row, orange marks an underfunded goal and green
/// a funded one; otherwise the caller's zero-balance color applies.
func balanceColor(_ category: CategoryBudget, goalsEnabled: Bool, zero: Color) -> Color {
    if category.isOverspent { return .red }
    if goalsEnabled, category.goal != nil {
        return category.isGoalUnderfunded ? .orange : .green
    }
    return category.available == 0 ? zero : .green
}

extension View {
    /// The web's CarryoverIndicator: a small arrow just past the balance's
    /// trailing edge, in the balance's color, when the category's overspending
    /// rolls into next month (GH #372). An overlay rather than a sibling so
    /// amounts stay column-aligned whether or not a row rolls over.
    func rolloverIndicator(_ shown: Bool, color: Color) -> some View {
        overlay(alignment: .trailing) {
            if shown {
                Image(systemName: "arrow.right")
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(color)
                    .offset(x: 10)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityHint(shown ? "Overspending rolls over to next month" : "")
    }
}

/// Whether `month` ("YYYY-MM") is before the current calendar month. The
/// strings are zero-padded, so a plain lexicographic compare is exact.
@MainActor private func isPastMonth(_ month: String) -> Bool {
    month < BudgetView.currentMonthString()
}

/// The tracking-budget result figure for the summary bar: actual savings once
/// a month is finished, projected savings while it's still current or ahead.
/// Mirrors the Actual webapp, which flips "Projected savings" to "Saved" when
/// the month rolls over.
@MainActor private func trackingSavings(_ budget: BudgetMonth) -> Int {
    isPastMonth(budget.month) ? budget.savedActual : budget.projectedSavings
}

@MainActor private func trackingSavingsLabel(_ budget: BudgetMonth) -> String {
    isPastMonth(budget.month) ? "Saved" : "Projected"
}

/// Clean-style summary card: a 2x2 grid whose reading order follows the
/// money — came in, allocated, went out, left over. Two rows because four
/// currency amounts don't fit across narrow devices.
struct CleanBudgetSummary: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let budget: BudgetMonth

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top) {
                SummaryStat(
                    label: "Income",
                    value: budgetStore.displayBalance(budget.totalIncome)
                )
                Spacer()
                SummaryStat(
                    label: "Budgeted",
                    value: budgetStore.displayBalance(budget.totalBudgeted),
                    alignment: .trailing
                )
            }
            HStack(alignment: .top) {
                SummaryStat(
                    label: "Spent",
                    value: budgetStore.displayBalance(-budget.totalSpent)
                )
                Spacer()
                // Envelope budgets lead with unallocated funds; tracking
                // budgets report savings instead — actual for a finished month,
                // projected for the current/future month.
                if let toBudget = budget.toBudget {
                    SummaryStat(
                        label: "To Budget",
                        value: budgetStore.displayBalance(toBudget),
                        valueColor: toBudget >= 0 ? .green : .red,
                        alignment: .trailing
                    )
                } else {
                    let value = trackingSavings(budget)
                    SummaryStat(
                        label: trackingSavingsLabel(budget),
                        value: budgetStore.displayBalance(value),
                        valueColor: value >= 0 ? .green : .red,
                        alignment: .trailing
                    )
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// The leading figure in the summary bar (To Budget / Income).
struct SummaryStat: View {
    let label: String
    let value: String
    var valueColor: Color = .primary
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .foregroundColor(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .animatedAmount(value)
        }
    }
}

/// Clean section header with collapse and visibility controls.
struct BudgetGroupHeader: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    let name: String
    let isCollapsed: Bool
    var isHidden = false
    var onSetHidden: ((Bool) -> Void)?
    /// Income groups show the money received beside their name.
    var receivedTotal: Int? = nil
    let onToggleCollapse: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleCollapse) {
                HStack(alignment: .top, spacing: 4) {
                    // Keep the chevron centered against a name that can wrap.
                    HStack(spacing: 4) {
                        DisclosureChevron(
                            isExpanded: !isCollapsed,
                            font: .caption2.weight(.semibold)
                        )
                        .foregroundStyle(.secondary)
                        Text(name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                    }
                    Spacer(minLength: 4)
                    if let receivedTotal {
                        Text("Received \(budgetStore.displayBalance(receivedTotal))")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(ReportStrings.text("Toggles the group's categories", locale: locale, bundle: .main))

            if let onSetHidden {
                Menu {
                    Button {
                        onSetHidden(!isHidden)
                    } label: {
                        Label(
                            ReportStrings.text(isHidden ? "Show Group" : "Hide Group", locale: locale, bundle: .main),
                            systemImage: isHidden ? "eye" : "eye.slash"
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(minWidth: 32, minHeight: 44)
                }
                .accessibilityLabel(ReportStrings.format("Options for %@", name, locale: locale, bundle: .main))
            }
        }
        .opacity(isHidden ? 0.5 : 1)
    }

    private var accessibilityLabel: String {
        let state = isCollapsed
            ? ReportStrings.text("collapsed", locale: locale, bundle: .main)
            : ReportStrings.text("expanded", locale: locale, bundle: .main)
        if let receivedTotal {
            return ReportStrings.format("%@, %@, received %@", name, state, budgetStore.displayBalance(receivedTotal), locale: locale, bundle: .main)
        }
        return ReportStrings.format("%@, %@", name, state, locale: locale, bundle: .main)
    }
}

/// One income category: name and the amount received this month. Tracking
/// budgets can budget income, so they also get a "Budgeted" caption.
struct IncomeCategoryRow: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    let income: IncomeCategory
    var isHidden = false
    var isDimmed = false
    var onSetHidden: ((Bool) -> Void)?
    var showsBudgeted = false
    var onShowTransactions: (IncomeCategory, String?) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    onShowTransactions(income, nil)
                } label: {
                    TwoLineName(
                        text: income.categoryName,
                        font: .body,
                        minimumScaleFactor: 0.85
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ReportStrings.format("All transactions for %@", income.categoryName, locale: locale, bundle: .main))

                Spacer()

                Button { onShowTransactions(income, income.month) } label: {
                    Text(budgetStore.displayBalance(income.received))
                        .foregroundColor(income.received > 0 ? .green : .secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(BudgetCategoryAccessibility.monthTransactions(
                    category: income.categoryName,
                    month: MonthPicker.title(for: income.month, locale: locale),
                    locale: locale
                ))
            }
            if showsBudgeted {
                Text("Budgeted: \(budgetStore.displayBalance(income.budgeted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listRowInsets(EdgeInsets(
            top: 4,
            leading: 16,
            bottom: 4,
            trailing: 16
        ))
        .opacity(isDimmed ? 0.5 : 1)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let onSetHidden {
                Button {
                    onSetHidden(!isHidden)
                } label: {
                    Label(BudgetCategoryAccessibility.visibility(isHidden: isHidden, locale: locale), systemImage: isHidden ? "eye" : "eye.slash")
                }
                .tint(isHidden ? .accentColor : .secondary)
            }
        }
    }
}

/// A compact category editor. Amount cells in the budget table keep their
/// existing actions; tapping the name is reserved for the category's own
/// metadata and quick-assignment shortcuts.
struct CategoryBudgetDetailSheet: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let category: CategoryBudget

    @State private var name: String
    @State private var editingNote = false
    @State private var note: EntityNote = .unsupported
    @State private var history: [CategoryBudget] = []
    @State private var rolloverEnabled: Bool
    @State private var isSavingName = false
    @State private var isSavingRollover = false
    @State private var isApplyingSuggestion = false
    @State private var isApplyingTemplate = false
    @State private var editingAutomations = false
    @State private var errorMessage: String?

    init(category: CategoryBudget) {
        self.category = category
        _name = State(initialValue: category.categoryName)
        _rolloverEnabled = State(initialValue: category.carryoverEnabled)
    }

    private var isTracking: Bool {
        budgetStore.currentBudgetMonth?.isTrackingBudget == true
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var quickAssignSuggestions: [QuickAssignSuggestion] {
        category.quickAssignSuggestions(history: history)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Category Name", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("categoryEditor.name")
                }

                if note.supported {
                    Section("Note") {
                        Button {
                            editingNote = true
                        } label: {
                            if note.isEmpty {
                                Label("Add Note", systemImage: "note.text.badge.plus")
                            } else {
                                Text(NoteLinkText.attributed(note.text))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .accessibilityIdentifier("categoryEditor.note")
                    }
                }

                if budgetStore.goalTemplatesEnabled {
                    goalSection
                }

                Section {
                    // The binding, not onChange, kicks off the write: a failed
                    // save reverts the state directly, which must not re-save.
                    // The guard covers a second tap landing before .disabled
                    // re-renders, so two writes can't race for the same rows.
                    Toggle("Rollover Overspending", isOn: Binding(
                        get: { rolloverEnabled },
                        set: { enabled in
                            guard !isSavingRollover else { return }
                            isSavingRollover = true
                            rolloverEnabled = enabled
                            Task { await saveRollover(enabled) }
                        }
                    ))
                    .disabled(isSavingRollover)
                    .accessibilityIdentifier("categoryEditor.rollover")
                } footer: {
                    Text(isTracking
                        ? ReportStrings.format("Carry this category's balance into next month. Applies from %@ onward.", MonthPicker.title(for: category.month, locale: locale), locale: locale, bundle: .main)
                        : ReportStrings.format("Carry overspending into next month instead of taking it from To Budget. Applies from %@ onward.", MonthPicker.title(for: category.month, locale: locale), locale: locale, bundle: .main))
                }

                Section(
                    content: {
                    // A suggestion overwrites this month's amount, so name the
                    // month and show what's there now — otherwise the user
                    // confirms a budget write blind.
                    LabeledContent(MonthPicker.title(for: category.month, locale: locale)) {
                        Text(budgetStore.displayBalance(category.budgeted))
                            .monospacedDigit()
                    }
                    .accessibilityIdentifier("categoryEditor.currentAmount")

                    if quickAssignSuggestions.isEmpty {
                        Text("No suggestions available")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(quickAssignSuggestions) { suggestion in
                            Button {
                                Task { await apply(suggestion) }
                            } label: {
                                HStack {
                                        Text(Self.quickAssignTitle(
                                            for: suggestion.kind,
                                            isTracking: isTracking,
                                            historyCount: history.count,
                                            locale: locale,
                                            bundle: .main
                                        ))
                                        .foregroundStyle(.tint)
                                    Spacer(minLength: 12)
                                    Text(budgetStore.displayBalance(suggestion.amount))
                                        .foregroundStyle(.primary)
                                        .monospacedDigit()
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(isApplyingSuggestion)
                            .accessibilityIdentifier("categoryEditor.quickAssign.\(suggestion.kind.rawValue)")
                        }
                    }
                    },
                    header: {
                        Text(ReportStrings.text(isTracking ? "Quick Budget" : "Quick Assign", locale: locale, bundle: .main))
                            .accessibilityIdentifier("categoryEditor.quickAssignHeader")
                    },
                    footer: {
                        Text("Suggestions use this category's existing Actual history and replace the amount shown above.")
                    }
                )

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await saveName() }
                    }
                    .disabled(isSavingName || trimmedName.isEmpty)
                }
            }
            .task { await reloadSupportingDetails() }
            .sheet(isPresented: $editingNote, onDismiss: {
                Task { note = await budgetStore.fetchNote(id: category.categoryId) }
            }) {
                NoteEditorView(
                    noteId: category.categoryId,
                    title: trimmedName.isEmpty ? category.categoryName : trimmedName,
                    note: note.text
                )
            }
            .sheet(isPresented: $editingAutomations) {
                BudgetAutomationsSheet(categoryId: category.categoryId, month: category.month)
            }
            .disabled(isSavingName)
            .interactiveDismissDisabled(isSavingName)
        }
    }

    /// Goal status mirroring the web's balance tooltip: funding state against
    /// the goal, the goal type (long-term `#goal` vs template automation), and
    /// the tracked amount. Templates are set in the category note (`#template`
    /// / `#goal` lines) and applied from the month's template actions.
    @ViewBuilder private var goalSection: some View {
        Section(
            content: {
                if let goal = category.goal, let difference = category.differenceToGoal {
                    LabeledContent(ReportStrings.text("Status", locale: locale, bundle: .main)) {
                        if difference == 0 {
                            Text("Fully Funded").foregroundStyle(.green)
                        } else if difference > 0 {
                            Text(ReportStrings.format("Overfunded (%@)", budgetStore.displayBalance(difference), locale: locale, bundle: .main))
                                .foregroundStyle(.green)
                        } else {
                            Text(ReportStrings.format("Underfunded (%@)", budgetStore.displayBalance(difference), locale: locale, bundle: .main))
                                .foregroundStyle(.orange)
                        }
                    }
                    LabeledContent(ReportStrings.text("Goal Type", locale: locale, bundle: .main), value: ReportStrings.text(category.longGoal ? "Goal" : "Automation", locale: locale, bundle: .main))
                    LabeledContent(ReportStrings.text("Goal", locale: locale, bundle: .main)) {
                        Text(budgetStore.displayBalance(goal)).monospacedDigit()
                    }
                    LabeledContent(ReportStrings.text(category.longGoal ? "Balance" : "Budgeted", locale: locale, bundle: .main)) {
                        Text(budgetStore.displayBalance(category.goalTrackedAmount))
                            .monospacedDigit()
                    }
                }
                if budgetStore.goalTemplatesUIEnabled {
                    Button {
                        editingAutomations = true
                    } label: {
                        Label("Edit Automations", systemImage: "slider.horizontal.3")
                    }
                }
                Button {
                    Task { await applyTemplate() }
                } label: {
                    Label("Apply Budget Template", systemImage: "wand.and.stars")
                }
                .disabled(isApplyingTemplate)
            },
            header: {
                Text("Goal")
            },
            footer: {
                if category.goal == nil, !budgetStore.goalTemplatesUIEnabled {
                    Text("Define templates with #template or #goal lines in this category's note, then apply them here.")
                }
            }
        )
    }

    private func applyTemplate() async {
        isApplyingTemplate = true
        errorMessage = nil
        let outcome = await budgetStore.runGoalTemplates(
            month: category.month, action: .apply, categoryId: category.categoryId)
        switch outcome {
        case .applied:
            dismiss()
        case .upToDate:
            errorMessage = ReportStrings.text("No templates to apply for this category.", locale: locale, bundle: .main)
            isApplyingTemplate = false
        case .errors(let errors):
            errorMessage = errors.joined(separator: "\n")
            isApplyingTemplate = false
        case .failed(let message):
            errorMessage = message
            isApplyingTemplate = false
        case .checkPassed:
            isApplyingTemplate = false
        }
    }

    private func reloadSupportingDetails() async {
        async let fetchedNote = budgetStore.fetchNote(id: category.categoryId)
        async let fetchedHistory = budgetStore.budgetHistory(for: category)
        note = await fetchedNote
        history = await fetchedHistory
    }

    nonisolated static func quickAssignTitle(
        for kind: QuickAssignSuggestion.Kind,
        isTracking: Bool,
        historyCount: Int,
        locale: Locale,
        bundle: Bundle
    ) -> String {
        switch kind {
        case .spentLastMonth: ReportStrings.text("Spent Last Month", locale: locale, bundle: bundle)
        case .averageSpent: ReportStrings.localized("Average Spent (\(historyCount) Months)", locale: locale, bundle: bundle)
        case .assignedLastMonth:
            isTracking
                ? ReportStrings.text("Budgeted Last Month", locale: locale, bundle: bundle)
                : ReportStrings.text("Assigned Last Month", locale: locale, bundle: bundle)
        case .resetAvailable:
            isTracking
                ? ReportStrings.text("Reset Balance to Zero", locale: locale, bundle: bundle)
                : ReportStrings.text("Reset Available to Zero", locale: locale, bundle: bundle)
        case .setToZero:
            isTracking
                ? ReportStrings.text("Set Budget to Zero", locale: locale, bundle: bundle)
                : ReportStrings.text("Set Assigned to Zero", locale: locale, bundle: bundle)
        }
    }

    private func apply(_ suggestion: QuickAssignSuggestion) async {
        isApplyingSuggestion = true
        errorMessage = nil
        do {
            try await budgetStore.setBudgetAmount(
                month: category.month,
                categoryId: category.categoryId,
                amountCents: suggestion.amount
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isApplyingSuggestion = false
        }
    }

    /// Writes immediately, like the web's balance menu — a rollover change
    /// is a budget edit, not part of the name draft the Save button commits.
    private func saveRollover(_ enabled: Bool) async {
        errorMessage = nil
        do {
            try await budgetStore.setBudgetCarryover(
                month: category.month,
                categoryId: category.categoryId,
                enabled: enabled
            )
        } catch {
            errorMessage = error.localizedDescription
            rolloverEnabled = !enabled
        }
        isSavingRollover = false
    }

    private func saveName() async {
        guard trimmedName != category.categoryName else {
            dismiss()
            return
        }
        isSavingName = true
        errorMessage = nil
        do {
            try await budgetStore.renameCategory(
                id: category.categoryId,
                name: trimmedName,
                month: category.month
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSavingName = false
        }
    }
}

/// One place for the status color and mode-neutral wording, shared by the
/// bar, the dot, and the detail sheet — so VoiceOver says the same thing for
/// the same category everywhere. The detail sheet keeps its own
/// envelope/tracking titles on top of this.
extension CategoryProgressState {
    var tint: Color {
        switch self {
        case .overspent: .red
        case .spent: .orange
        case .spending: .blue
        case .funded: .green
        case .unassigned: .secondary
        }
    }

    var statusText: String {
        statusText(locale: .autoupdatingCurrent)
    }

    func statusText(locale: Locale, bundle: Bundle = .main) -> String {
        switch self {
        case .overspent: ReportStrings.text("budget.status.overspent", locale: locale, bundle: bundle)
        case .spent: ReportStrings.text("budget.status.fullySpent", locale: locale, bundle: bundle)
        case .spending: ReportStrings.text("budget.status.partiallySpent", locale: locale, bundle: bundle)
        case .funded: ReportStrings.text("budget.status.funded", locale: locale, bundle: bundle)
        case .unassigned: ReportStrings.text("budget.status.noMoneyAssigned", locale: locale, bundle: bundle)
        }
    }
}

/// Spent-vs-available bar for a budget row. Fill and color mirror the row's
/// Available amount: green while money remains, red once overspent.
struct CategoryProgressBar: View {
    @Environment(\.locale) private var locale
    let fraction: Double
    let state: CategoryProgressState

    private var trackTint: Color {
        state == .funded ? state.tint.opacity(0.25) : Color(.systemFill)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackTint)
                Capsule()
                    .fill(state.tint)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 5)
        // Budgeting a category shrinks its bar as the money lands, so the
        // edit is visible in the row itself and not only in the pill.
        .animation(AppAnimation.amount, value: fraction)
        .accessibilityElement()
        .accessibilityLabel(ReportStrings.format(
            "%@, spent %lld percent of available",
            state.statusText(locale: locale, bundle: .main),
            Int64((fraction * 100).rounded()),
            locale: locale,
            bundle: .main
        ))
    }
}

/// A deliberately quiet status cue for budget rows. The category detail sheet
/// carries the full plain-language status so the main budget remains scannable.
struct CompactCategoryStatusDot: View {
    @Environment(\.locale) private var locale
    let state: CategoryProgressState

    var body: some View {
        Circle()
            .fill(state.tint)
            .frame(width: 7, height: 7)
            .accessibilityLabel(state.statusText(locale: locale, bundle: .main))
            .accessibilityIdentifier("categoryStatusDot")
    }
}

/// Edit the budgeted amount for one category-month. Saving writes through
/// the sync engine (optimistic local-first) and refreshes the month.
struct EditBudgetAmountSheet: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let category: CategoryBudget

    @State private var amountText: String
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(category: CategoryBudget) {
        self.category = category
        let initial = category.budgeted == 0
            ? ""
            : String(format: "%.2f", Double(category.budgeted) / 100.0)
        _amountText = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AmountInputField(
                        text: $amountText,
                        conventionalAmountEntry: budgetStore.conventionalAmountEntry,
                        allowsNegative: true,
                        autofocus: true
                    )
                } header: {
                    Text(ReportStrings.format("Budgeted in %@", MonthPicker.title(for: category.month, locale: locale), locale: locale, bundle: .main))
                } footer: {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(category.categoryName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaving)
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(isSaving)
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                // An emptied field means "no longer budgeted", i.e. zero.
                let cents = try BudgetStore.budgetAmountCents(
                    from: amountText.isEmpty ? "0" : amountText,
                    allowNegative: true
                )
                try await budgetStore.setBudgetAmount(
                    month: category.month,
                    categoryId: category.categoryId,
                    amountCents: cents
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

struct MonthPicker: View {
    @Binding var selectedMonth: String
    @Environment(\.locale) private var locale

    var body: some View {
        Menu {
            Picker("Month", selection: $selectedMonth) {
                ForEach(monthOptions, id: \.self) { month in
                    Text(Self.title(for: month, locale: locale)).tag(month)
                }
            }
        } label: {
            Text(Self.shortTitle(for: selectedMonth, locale: locale))
                .font(.headline)
                .lineLimit(1)
        }
        // The abbreviation is a layout constraint, not what the month is
        // called — VoiceOver still reads it in full.
        .accessibilityLabel(Self.title(for: selectedMonth, locale: locale))
    }

    /// Next month back through the prior year, newest first, padded with the
    /// selection itself when swiping has moved outside that window.
    private var monthOptions: [String] {
        let current = BudgetView.currentMonthString()
        var months = (-12...1).map { BudgetView.shiftMonth(current, by: $0) }
        if !months.contains(selectedMonth) {
            months.append(selectedMonth)
            months.sort()
        }
        return months.reversed()
    }

    nonisolated static func title(for month: String, locale: Locale = .autoupdatingCurrent) -> String {
        guard let date = date(fromMonth: month) else {
            return month
        }
        return Self.formatter(template: "yMMMM", locale: locale).string(from: date)
    }

    /// `title(for:)` abbreviated to a fixed-ish width for the toolbar stepper.
    nonisolated static func shortTitle(for month: String, locale: Locale = .autoupdatingCurrent) -> String {
        guard let date = date(fromMonth: month) else {
            return month
        }
        return Self.formatter(template: "yMMM", locale: locale).string(from: date)
    }

    private nonisolated static func formatter(template: String, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale) ?? template
        return formatter
    }

    nonisolated static func date(fromMonth month: String) -> Date? {
          let parts = month.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[0].allSatisfy(\.isNumber),
              parts[1].allSatisfy(\.isNumber),
              let year = Int(parts[0]),
              year > 0,
              let monthNumber = Int(parts[1]),
              (1...12).contains(monthNumber) else {
            return nil
        }
        var components = DateComponents()
        components.year = year
        components.month = monthNumber
        components.day = 1
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        calendar.timeZone = utc
        return calendar.date(from: components)
    }
}

#Preview {
    BudgetView()
        .environmentObject(BudgetStore.previewInstance())
}
