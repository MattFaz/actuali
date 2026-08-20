import SwiftUI

/// Cached formatters for the "yyyy-MM" month keys used by the budget tables
/// and the month title shown in the toolbar. DateFormatter construction is
/// expensive, so these are built once rather than per render.
private let yearMonthFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM"
    return formatter
}()

private let monthTitleFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMMM yyyy"
    return formatter
}()

/// Shared metrics for the budget table's three numeric columns, so the
/// summary captions, group totals and category pills line up vertically
/// like the PWA's table.
enum BudgetColumn {
    static let width: CGFloat = 70
    // Tight: every point between the columns comes out of the category
    // name, which wraps early on a phone ("Caravan Parks 🏕" drops its
    // emoji to a second line).
    static let spacing: CGFloat = 4

    /// Cell text for the budget table: a plain grouped number without the
    /// currency symbol, like the PWA's budget table — "USD 1,850.00" in
    /// every cell would drown the category names on a phone.
    static func text(_ cents: Int) -> String {
        (Double(cents) / 100.0).formatted(.number.precision(.fractionLength(2)))
    }
}

private extension BudgetStore {
    /// Masked variant of `BudgetColumn.text` for the budget table's cells.
    /// Lives here rather than on the store proper so the table's
    /// symbol-less number format stays private to this file.
    func displayBudgetCell(_ cents: Int) -> String {
        hideBalances ? Self.hiddenBalanceText : BudgetColumn.text(cents)
    }
}

struct BudgetView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @State private var selectedMonth = currentMonthString()
    @State private var editingCategory: CategoryBudget?
    @State private var selectedCategory: CategoryBudget?
    @State private var transferContext: BudgetTransferContext?
    @State private var transactionsDestination: CategoryTransactionsDestination?
    @State private var newBudgetItem: NewBudgetItem?
    @State private var categoryFilter: BudgetCategoryFilter = .all
    /// Comma-joined group ids the user has collapsed, PWA-style. Stored as a
    /// string because @AppStorage can't hold a Set directly.
    @AppStorage("collapsedBudgetGroups") private var collapsedGroupsStorage = ""

    private var collapsedGroups: Set<String> {
        Set(collapsedGroupsStorage.split(separator: ",").map(String.init))
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
        let groups = collapsedGroups.union(groupedCategories.map(\.id))
        collapsedGroupsStorage = groups.sorted().joined(separator: ",")
    }

    private func expandAllGroups() {
        let groups = collapsedGroups.subtracting(groupedCategories.map(\.id))
        collapsedGroupsStorage = groups.sorted().joined(separator: ",")
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
                            description: Text("You're connected. Choose a budget in Settings to load it here.")
                        )
                    } else {
                        ContentUnavailableView(
                            "No Budget Loaded",
                            systemImage: "chart.pie",
                            description: Text("Go to Settings to connect to your Actual Budget server")
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
            .toolbar { budgetToolbar }
            .onChange(of: selectedMonth) { _, newMonth in
                Task {
                    await budgetStore.fetchBudgetMonth(newMonth)
                }
            }
            .refreshable {
                await budgetStore.sync()
                // sync() refreshes the current calendar month; re-fetch in
                // case the user is viewing a different month.
                await budgetStore.fetchBudgetMonth(selectedMonth)
            }
            .sheet(item: $editingCategory) { category in
                EditBudgetAmountSheet(category: category)
            }
            .sheet(item: $selectedCategory) { category in
                CategoryBudgetDetailSheet(category: category)
            }
            .sheet(item: $transferContext) { context in
                BudgetTransferSheet(context: context)
            }
            .sheet(item: $newBudgetItem, onDismiss: reloadAfterCreating) { item in
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
        }
        .initialSyncBanner()
    }

    /// One group's rows, extracted from the `List` so the body stays within
    /// the compiler's type-check budget.
    @ViewBuilder
    private func groupSection(_ group: CategoryGroupSection) -> some View {
        let isCollapsed = collapsedGroups.contains(group.id)
        if budgetStore.budgetDisplayStyle == .clean {
            // Clean style: the group name sits above the card as a section
            // header, like the App Store screenshots. The same collapse
            // control lives there so collapsing behaves identically in both
            // styles.
            Section {
                if !isCollapsed {
                    ForEach(group.categories) { category in
                        CleanCategoryBudgetRow(
                            category: category,
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
                    onToggleCollapse: { toggleCollapsed(group.id) }
                )
                .textCase(nil)
            }
        } else {
            // The group row lives inside the card (first row, tinted) like
            // the PWA's table, so its totals share the exact column grid of
            // the rows below.
            Section {
                BudgetGroupHeader(
                    name: group.name,
                    isCollapsed: isCollapsed,
                    totals: budgetStore.showGroupTotals ? group.totals : nil,
                    onToggleCollapse: { toggleCollapsed(group.id) },
                    reservesTwoLines: true
                )
                .listRowBackground(Color(.tertiarySystemFill))
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 16))
                if !isCollapsed {
                    ForEach(group.categories) { category in
                        CategoryBudgetRow(
                            category: category,
                            onShowDetails: { selectedCategory = $0 },
                            onEditBudget: { editingCategory = $0 },
                            // Name shows all time, Spent shows
                            // the displayed month (GH #56).
                            onShowTransactions: showTransactions,
                            onMoveMoney: moveMoney
                        )
                    }
                }
            }
        }
    }

    /// The screen's toolbar, extracted from `body` so the whole screen stays
    /// within the compiler's type-check budget.
    @ToolbarContentBuilder
    private var budgetToolbar: some ToolbarContent {
        // Both arrows flank the month in the center, so nothing sits in
        // the leading "back button" position where the previous-month
        // chevron used to be mistaken for one (it steps the month, not
        // the navigation stack).
        ToolbarItem(placement: .principal) {
            HStack(spacing: 8) {
                Button {
                    selectedMonth = Self.shiftMonth(selectedMonth, by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Previous month")

                MonthPicker(selectedMonth: $selectedMonth)

                Button {
                    selectedMonth = Self.shiftMonth(selectedMonth, by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .accessibilityLabel("Next month")
            }
        }
        // Creation, unlike everything in the options menu, changes
        // the budget rather than the view of it — so it gets its own
        // button (GH #284). Nothing to add to until a budget is open.
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
                        Label("New Category Group", systemImage: "folder")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add")
                .accessibilityHint("Create a category or category group")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            // Every "how should this look" control lives here (GH
            // #157). Whole-table expand/collapse is a menu rather
            // than a long-press on the group headers: SwiftUI context
            // menus don't fire inside the clean style's section
            // headers (GH #130).
            let hasBudget = budgetStore.currentBudgetMonth != nil
            BudgetOptionsMenu(
                categoryFilter: $categoryFilter,
                isTrackingBudget: budgetStore.currentBudgetMonth?.isTrackingBudget == true,
                expandAllGroups: hasBudget ? { expandAllGroups() } : nil,
                collapseAllGroups: hasBudget ? { collapseAllGroups() } : nil
            )
        }
    }

    /// The pinned summary plus the scrolling budget table, shown once a
    /// budget month has loaded. Extracted from `body` so the whole screen
    /// stays within the compiler's type-check budget.
    @ViewBuilder
    private func loadedBudgetContent(_ budget: BudgetMonth) -> some View {
        VStack(spacing: 0) {
            // Summary card: the clean style reads as a 2x2 grid of
            // currency amounts; the detailed style's captioned
            // columns double as the column headers for the table
            // below. It sits above the List (not inside it) so it
            // stays pinned while the table scrolls (GH #155).
            Group {
                if budgetStore.budgetDisplayStyle == .clean {
                    CleanBudgetSummary(budget: budget)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 24)
                                .fill(Color(.secondarySystemGroupedBackground))
                        )
                } else {
                    TableBudgetSummary(budget: budget)
                        // Fine-tune the fixed-width columns against
                        // the amount pills in the rows below.
                        .padding(.leading, 4)
                        .padding(.trailing, 4)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(Color(.secondarySystemGroupedBackground))
                        )
                }
            }
            // The List below overrides its default margins with
            // 4 pt content margins; match them so the summary is
            // the same width as the sections.
            .padding(.horizontal, 4)
            .padding(.top, 8)
            // A gutter that survives scrolling, unlike the List's
            // top content margin below. Without it the scrolled
            // rows clip flush against the capsule — a group header
            // sliced mid-glyph, its tinted background swallowing
            // the capsule's bottom corners (GH #165).
            .padding(.bottom, 8)

            List {
                BudgetCheckInSection(budget: budget)

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

                // Income group last, matching the bottom of the web
                // UI's budget table.
                if categoryFilter == .all, !budget.incomeCategories.isEmpty {
                    incomeSection(budget)
                }
            }
            // Collapse state lives in @AppStorage, and a write to
            // that lands outside any withAnimation transaction —
            // so the rows have to be animated from here, off the
            // stored value, rather than at the call site.
            .animation(AppAnimation.disclosure, value: collapsedGroupsStorage)
            // The clean style keeps the stock section rhythm; the
            // detailed table packs its group cards tighter.
            .listSectionSpacing(
                budgetStore.budgetDisplayStyle == .clean ? .default : .custom(14)
            )
            .contentMargins(.horizontal, 4, for: .scrollContent)
            // The rest of the gap under the pinned summary — this
            // part scrolls away with the content, leaving the 8 pt
            // gutter above. Together they sit a notch wider than
            // the spacing between the group sections, so the
            // summary reads as its own bar rather than a first
            // group (GH #165).
            .contentMargins(
                .top,
                budgetStore.budgetDisplayStyle == .clean ? 20 : 16,
                for: .scrollContent
            )
            // Let short rows (group headers) sit below the stock
            // 44 pt minimum; tap targets stay fine because the whole
            // row is the button.
            .environment(\.defaultMinListRowHeight, 32)
            // Rows leaving the table used to be chopped off flat
            // against the gutter under the summary, a hard grey
            // line across mid-row. Fade them into it instead. The
            // List's top content margin above is deeper than this
            // fade, so at rest it covers empty background and
            // nothing on screen looks washed out.
            .overlay(alignment: .top) {
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
        // The budget table is a fixed grid of narrow amount
        // columns; stretched to iPad width it becomes a category
        // name and its numbers separated by a foot of nothing.
        .readableWidth()
        // The pinned summary sits outside the List, so paint the
        // grouped background behind it to match.
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    /// The income group drawn at the bottom of the table, extracted from the
    /// `List` so the body stays within the compiler's type-check budget.
    @ViewBuilder
    private func incomeSection(_ budget: BudgetMonth) -> some View {
        Section {
            ForEach(budget.incomeCategories) { income in
                IncomeCategoryRow(
                    income: income,
                    // Only tracking budgets budget income;
                    // envelope budgets just receive it.
                    showsBudgeted: budget.toBudget == nil,
                    onShowTransactions: showTransactions
                )
            }
        } header: {
            HStack {
                Text(budget.incomeCategories.first?.groupName ?? "Income")
                Spacer()
                Text("Received \(budgetStore.displayBalance(budget.totalIncome))")
            }
        }
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

    /// `createCategory`/`createCategoryGroup` refresh the current calendar
    /// month; if the table is showing a different one, fetch that too so the
    /// new row appears without a pull-to-refresh.
    private func reloadAfterCreating() {
        guard selectedMonth != Self.currentMonthString() else { return }
        Task { await budgetStore.fetchBudgetMonth(selectedMonth) }
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
        /// The rows to draw, after "Hide Spent Categories" filtering.
        let categories: [CategoryBudget]
        /// Totals over the group's whole category list, hidden rows included.
        let totals: CategoryGroupTotals
    }

    var groupedCategories: [CategoryGroupSection] {
        guard let budget = budgetStore.currentBudgetMonth else { return [] }
        let byGroup = Dictionary(grouping: budget.categoryBudgets, by: { $0.groupId })
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
                        categories: visible,
                        totals: CategoryGroupTotals(categoryFilter == .all ? items : visible)
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
            .filter { categoryFilter == .all && !$0.isIncome && !$0.hidden && $0.categories.isEmpty }
            .map { group -> (Double, CategoryGroupSection) in
                (
                    group.sortOrder,
                    CategoryGroupSection(
                        id: group.id,
                        name: group.name,
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

struct BudgetCheckInSection: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let budget: BudgetMonth
    @AppStorage("budgetCheckInExpanded") private var isExpanded = true

    private var hasIssues: Bool {
        budget.hasCheckInIssues(uncategorizedCount: budgetStore.uncategorizedCount)
    }

    var body: some View {
        Section {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                    Text("Budget Check-In")
                        .font(.headline)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Budget Check-In, \(isExpanded ? "expanded" : "collapsed")")

            if isExpanded, budget.overspentCount > 0 {
                NavigationLink {
                    OverspentCategoriesView()
                } label: {
                    Label(
                        budget.isTrackingBudget
                            ? "\(budget.overspentCount) over budget"
                            : "\(budget.overspentCount) overspent",
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .foregroundStyle(.red)
                }
                .accessibilityIdentifier("budgetCheckInOverspent")
            }

            if isExpanded, budgetStore.uncategorizedCount > 0 {
                NavigationLink {
                    UncategorizedTransactionsView()
                } label: {
                    Label(
                        "\(budgetStore.uncategorizedCount) uncategorized",
                        systemImage: "questionmark.circle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }

            if isExpanded, !budget.unassignedCategories.isEmpty {
                NavigationLink {
                    BudgetGuidanceCategoryList(
                        title: budget.isTrackingBudget ? "No Budget Set" : "Not Funded",
                        message: budget.isTrackingBudget
                            ? "These categories have no budget or activity this month."
                            : "These categories have no assigned or carried money this month.",
                        kind: .unassigned
                    )
                } label: {
                    Label(
                        budget.isTrackingBudget
                            ? "\(budget.unassignedCategories.count) without a budget"
                            : "\(budget.unassignedCategories.count) not funded",
                        systemImage: "circle.dashed"
                    )
                }
            }

            if isExpanded, !budget.approachingLimitCategories.isEmpty {
                NavigationLink {
                    BudgetGuidanceCategoryList(
                        title: budget.isTrackingBudget ? "Near Budget" : "Almost Spent",
                        message: "These categories have used at least 80% of their available amount.",
                        kind: .approachingLimit
                    )
                } label: {
                    Label(
                        "\(budget.approachingLimitCategories.count) nearing the limit",
                        systemImage: "gauge.with.dots.needle.67percent"
                    )
                    .foregroundStyle(.orange)
                }
            }

            if isExpanded, !hasIssues {
                Label("Budget looks good", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } footer: {
            if isExpanded {
                Text(budget.isTrackingBudget
                    ? "Review the plan against this month's actual activity."
                    : "Resolve the important items before assigning the rest of the month.")
            }
        }
    }
}

/// A focused check-in result. Selecting a category opens the same actionable
/// detail sheet as the main budget table, so guidance always ends in a real
/// resolution path rather than a dead-end status list.
struct BudgetGuidanceCategoryList: View {
    enum Kind {
        case unassigned
        case approachingLimit
    }

    @EnvironmentObject var budgetStore: BudgetStore
    let title: String
    let message: String
    let kind: Kind
    @State private var selectedCategory: CategoryBudget?
    @State private var editingCategory: CategoryBudget?

    private var categories: [CategoryBudget] {
        guard let budget = budgetStore.currentBudgetMonth else { return [] }
        switch kind {
        case .unassigned:
            return budget.unassignedCategories
        case .approachingLimit:
            return budget.approachingLimitCategories
        }
    }

    private var isTracking: Bool {
        budgetStore.currentBudgetMonth?.isTrackingBudget == true
    }

    var body: some View {
        List {
            Section {
                Text(message)
                    .foregroundStyle(.secondary)
            }
            Section {
                if categories.isEmpty {
                    Label("No categories need attention", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    ForEach(categories) { category in
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                selectedCategory = category
                            } label: {
                                // One explicit VStack: a Button lays multiple
                                // label views out side by side, which would
                                // squash the bar next to the Spacer'd row.
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(category.categoryName)
                                                .foregroundStyle(.primary)
                                            Text(category.groupName)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(budgetStore.displayBalance(category.available))
                                            .foregroundStyle(category.isOverspent ? .red : .secondary)
                                            .monospacedDigit()
                                    }
                                    if category.showsProgressBar {
                                        CategoryProgressBar(
                                            fraction: category.progressFraction,
                                            state: category.progressState
                                        )
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Details for \(category.categoryName)")

                            Button {
                                editingCategory = category
                            } label: {
                                Label(fundingActionTitle, systemImage: "plus.circle.fill")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("Fund \(category.categoryName)")
                        }
                    }
                }
            }
        }
        .readableWidth()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedCategory) { category in
            CategoryBudgetDetailSheet(category: category)
        }
        .sheet(item: $editingCategory) { category in
            EditBudgetAmountSheet(category: category)
        }
    }

    private var fundingActionTitle: String {
        switch (isTracking, kind) {
        case (true, .unassigned): "Add Budget"
        case (true, .approachingLimit): "Increase Budget"
        case (false, .unassigned): "Assign Money"
        case (false, .approachingLimit): "Assign More"
        }
    }
}

struct CategoryBudgetRow: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let category: CategoryBudget
    var onShowDetails: (CategoryBudget) -> Void = { _ in }
    var onEditBudget: (CategoryBudget) -> Void = { _ in }
    /// Push the category's transactions: month narrows to one "yyyy-MM",
    /// nil means all time (GH #56).
    var onShowTransactions: (CategoryBudget, String?) -> Void = { _, _ in }
    /// Open the move-money sheet for this category's balance (GH #128).
    var onMoveMoney: (CategoryBudget) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // One PWA-style table line: name, then the Budgeted/Spent/Balance
            // pills in their fixed columns. Each element keeps its own tap
            // action (our enhancement over the PWA's read-only cells).
            HStack(spacing: BudgetColumn.spacing) {
                Button {
                    onShowDetails(category)
                } label: {
                    HStack(spacing: 5) {
                        CompactCategoryStatusDot(state: category.progressState)
                        TwoLineName(
                            text: category.categoryName,
                            font: .subheadline,
                            minimumScaleFactor: 0.85
                        )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Details for \(category.categoryName)")
                Spacer(minLength: 4)
                Button {
                    onEditBudget(category)
                } label: {
                    BudgetAmountPill(
                        text: budgetStore.displayBudgetCell(category.budgeted),
                        dimmed: category.budgeted == 0
                    )
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Edit budgeted amount for \(category.categoryName)")
                Button {
                    onShowTransactions(category, category.month)
                } label: {
                    BudgetAmountPill(
                        text: budgetStore.displayBudgetCell(category.spent),
                        dimmed: category.spent == 0
                    )
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Transactions for \(category.categoryName) in \(MonthPicker.title(for: category.month))")
                // A zero balance has nothing to move and nothing to cover, so
                // it stays a plain cell.
                Button {
                    onMoveMoney(category)
                } label: {
                    BudgetAmountPill(
                        text: budgetStore.displayBudgetCell(category.available),
                        color: category.isOverspent ? .red : (category.available == 0 ? .secondary : .green)
                    )
                }
                .buttonStyle(.borderless)
                .disabled(category.available == 0)
                .accessibilityLabel(category.isOverspent
                    ? "Cover overspending for \(category.categoryName)"
                    : "Move money from \(category.categoryName)")
            }
            if budgetStore.showBudgetProgressBars, category.showsProgressBar {
                CategoryProgressBar(
                    fraction: category.progressFraction,
                    state: category.progressState
                )
            }
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 16))
    }
}

/// Clean-style category row, matching the App Store screenshots: name and a
/// large Available amount up top, the progress bar beneath, then tappable
/// Budgeted/Spent captions. Same tap actions as the detailed table's cells.
struct CleanCategoryBudgetRow: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let category: CategoryBudget
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
                        CompactCategoryStatusDot(state: category.progressState)
                        Text(category.categoryName)
                            .font(.body)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Details for \(category.categoryName)")
                Spacer()
                // A zero balance has nothing to move and nothing to cover, so
                // it stays a plain label.
                Button {
                    onMoveMoney(category)
                } label: {
                    Text(budgetStore.displayBalance(category.available))
                        .foregroundColor(category.isOverspent ? .red : .green)
                }
                .buttonStyle(.borderless)
                .disabled(category.available == 0)
                .accessibilityLabel(category.isOverspent
                    ? "Cover overspending for \(category.categoryName)"
                    : "Move money from \(category.categoryName)")
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
                .accessibilityLabel("Edit budgeted amount for \(category.categoryName)")
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
                .accessibilityLabel("Transactions for \(category.categoryName) in \(MonthPicker.title(for: category.month))")
            }
        }
        .padding(.vertical, 2)
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

/// PWA-style summary bar: unallocated funds lead, and the three captioned
/// columns double as the column headers for the table below.
struct TableBudgetSummary: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let budget: BudgetMonth

    var body: some View {
        HStack(alignment: .top, spacing: BudgetColumn.spacing) {
            // Envelope budgets lead with unallocated funds; tracking
            // budgets have no to-budget concept, so lead with income
            // received instead.
            if let toBudget = budget.toBudget {
                SummaryStat(
                    label: "To Budget",
                    value: budgetStore.displayBudgetCell(toBudget),
                    valueColor: toBudget >= 0 ? .green : .red
                )
            } else {
                SummaryStat(
                    label: "Income",
                    value: budgetStore.displayBudgetCell(budget.totalIncome)
                )
            }
            Spacer(minLength: 4)
            SummaryColumn(
                label: "Budgeted",
                value: budgetStore.displayBudgetCell(budget.totalBudgeted)
            )
            SummaryColumn(
                label: "Spent",
                value: budgetStore.displayBudgetCell(budget.totalSpent)
            )
            // Envelope budgets total the category balances; tracking budgets
            // report savings instead — actual for a finished month, projected
            // for the current/future month.
            if budget.toBudget != nil {
                SummaryColumn(
                    label: "Balance",
                    value: budgetStore.displayBudgetCell(budget.totalAvailable),
                    valueColor: budget.totalAvailable >= 0 ? .green : .red
                )
            } else {
                let value = trackingSavings(budget)
                SummaryColumn(
                    label: trackingSavingsLabel(budget),
                    value: budgetStore.displayBudgetCell(value),
                    valueColor: value >= 0 ? .green : .red
                )
            }
        }
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

/// One captioned column in the summary bar, sized to line up with the
/// category pills below it.
struct SummaryColumn: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundColor(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .animatedAmount(value)
        }
        .frame(width: BudgetColumn.width, alignment: .trailing)
    }
}

/// One amount cell in the budget table, in the PWA's pill style.
struct BudgetAmountPill: View {
    let text: String
    var color: Color = .primary
    var dimmed = false

    var body: some View {
        Text(text)
            .font(.footnote)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(dimmed ? Color.secondary : color)
            .animatedAmount(text)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(width: BudgetColumn.width, alignment: .trailing)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemFill).opacity(0.1))
            )
    }
}

/// Group header row: collapse control and group name; optionally shows the
/// group's Spent and Balance totals in the table's rightmost two columns.
///
/// Budgeted is deliberately absent. Pills are laid out from the trailing
/// edge, so omitting it hands its ~76 pt back to the group name — which
/// needs the room, since group names run longer than category names — while
/// Spent and Balance stay in their columns. The per-category Budgeted cells
/// are still there in the rows below for anyone who wants them.
struct BudgetGroupHeader: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let name: String
    let isCollapsed: Bool
    /// The detailed style totals its columns here; the clean style's header
    /// is a plain section title above the card, so it leaves this nil.
    var totals: CategoryGroupTotals?
    let onToggleCollapse: () -> Void
    /// The detailed style reserves two lines so group rows stay equal-height
    /// whether names wrap or not (GH #252); the clean style's plain section
    /// titles keep their natural height.
    var reservesTwoLines = false

    var body: some View {
        Button(action: onToggleCollapse) {
            HStack(spacing: BudgetColumn.spacing) {
                DisclosureChevron(
                    isExpanded: !isCollapsed,
                    font: .caption2.weight(.semibold)
                )
                .foregroundStyle(.secondary)
                if reservesTwoLines {
                    TwoLineName(
                        text: name,
                        font: .subheadline.weight(.semibold),
                        minimumScaleFactor: 0.85
                    )
                    .foregroundStyle(.primary)
                } else {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 4)
                if let totals {
                    BudgetAmountPill(
                        text: budgetStore.displayBudgetCell(totals.spent),
                        dimmed: totals.spent == 0
                    )
                    BudgetAmountPill(
                        text: budgetStore.displayBudgetCell(totals.balance),
                        // Same three-way treatment as the category rows, so a
                        // group that lands on zero doesn't read as healthy.
                        color: totals.balance < 0 ? .red : (totals.balance == 0 ? .secondary : .green)
                    )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Toggles the group's categories")
    }

    /// The pills are decoration to VoiceOver once the button carries its own
    /// label, so the totals have to be spoken here or they're lost. Currency
    /// formatting, not the table's symbol-less cells, reads better aloud.
    private var accessibilityLabel: String {
        let state = isCollapsed ? "collapsed" : "expanded"
        guard let totals else { return "\(name), \(state)" }
        return """
            \(name), \(state), \
            spent \(budgetStore.displayBalance(totals.spent)), \
            balance \(budgetStore.displayBalance(totals.balance))
            """
    }
}

/// One income category: name and the amount received this month. Tracking
/// budgets can budget income, so they also get a "Budgeted" caption.
struct IncomeCategoryRow: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let income: IncomeCategory
    var showsBudgeted = false
    var onShowTransactions: (IncomeCategory, String?) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    onShowTransactions(income, nil)
                } label: {
                    TwoLineName(text: income.categoryName, font: .body)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("All transactions for \(income.categoryName)")

                Spacer()

                Button {
                    onShowTransactions(income, income.month)
                } label: {
                    Text(budgetStore.displayBalance(income.received))
                        .foregroundColor(income.received > 0 ? .green : .secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Transactions for \(income.categoryName) in \(MonthPicker.title(for: income.month))")
            }
            if showsBudgeted {
                Text("Budgeted: \(budgetStore.displayBalance(income.budgeted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }
}

/// One YNAB-style place to understand and act on a category without losing
/// the month context. Actual's tracking budgets keep their own terminology.
struct CategoryBudgetDetailSheet: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let category: CategoryBudget

    @State private var editingBudget = false
    @State private var transferContext: BudgetTransferContext?
    @State private var editingNote = false
    @State private var note: EntityNote = .unsupported
    @State private var recentTransactions: [Transaction] = []
    @State private var history: [CategoryBudget] = []
    @State private var isApplyingSuggestion = false
    @State private var quickAssignError: String?
    @AppStorage("budgetDetailActionsExpanded") private var actionsExpanded = true
    @AppStorage("budgetDetailQuickAssignExpanded") private var quickAssignExpanded = true

    private var isTracking: Bool {
        budgetStore.currentBudgetMonth?.isTrackingBudget == true
    }

    /// The sheet item is a snapshot taken at tap time; read the row live from
    /// the store so Assign/Cover done from inside this sheet update the
    /// figures immediately instead of only after reopening.
    private var liveCategory: CategoryBudget {
        budgetStore.currentBudgetMonth?.categoryBudgets
            .first { $0.categoryId == category.categoryId && $0.month == category.month }
            ?? category
    }

    private var quickAssignSuggestions: [QuickAssignSuggestion] {
        liveCategory.quickAssignSuggestions(history: history)
    }

    private var statusTitle: String {
        switch (isTracking, liveCategory.progressState) {
        case (_, .overspent): isTracking ? "Over budget" : "Overspent"
        case (true, .funded): "Budget set"
        case (false, .funded): "Funded"
        case (true, .spending): "Within budget"
        case (false, .spending): "On track"
        case (true, .spent): "Budget used"
        case (false, .spent): "Fully spent"
        case (true, .unassigned): "No budget set"
        case (false, .unassigned): "Not funded"
        }
    }

    private var statusColor: Color {
        liveCategory.progressState.tint
    }

    private var statusIcon: String {
        switch liveCategory.progressState {
        case .overspent: "exclamationmark.circle.fill"
        case .unassigned: "circle.dashed"
        case .funded, .spending, .spent: "checkmark.circle.fill"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(statusTitle, systemImage: statusIcon)
                                .font(.headline)
                                .foregroundStyle(statusColor)
                            Spacer()
                            Text(MonthPicker.title(for: category.month))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        CategoryProgressBar(
                            fraction: liveCategory.progressFraction,
                            state: liveCategory.progressState
                        )
                        LabeledContent(isTracking ? "Budget" : "Assigned") {
                            Text(budgetStore.displayBalance(liveCategory.budgeted))
                        }
                        LabeledContent("Activity") {
                            Text(budgetStore.displayBalance(liveCategory.spent))
                        }
                        LabeledContent(isTracking ? "Balance" : "Available") {
                            Text(budgetStore.displayBalance(liveCategory.available))
                                .foregroundStyle(statusColor)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    if actionsExpanded {
                        Button {
                            editingBudget = true
                        } label: {
                            Label(isTracking ? "Edit Budget" : "Assign Money", systemImage: "pencil")
                        }

                        if liveCategory.available != 0,
                           let budget = budgetStore.currentBudgetMonth {
                            Button {
                                transferContext = BudgetTransferContext(category: liveCategory, budget: budget)
                            } label: {
                                Label(
                                    isTracking
                                        ? "Reallocate Budget"
                                        : (liveCategory.isOverspent ? "Cover Overspending" : "Move Money"),
                                    systemImage: "arrow.left.arrow.right"
                                )
                            }
                        }

                        NavigationLink {
                            CategoryTransactionsView(destination: CategoryTransactionsDestination(
                                categoryId: category.categoryId,
                                categoryName: category.categoryName,
                                month: category.month
                            ))
                        } label: {
                            Label("This Month's Transactions", systemImage: "list.bullet.rectangle")
                        }

                        NavigationLink {
                            CategoryTransactionsView(destination: CategoryTransactionsDestination(
                                categoryId: category.categoryId,
                                categoryName: category.categoryName,
                                month: nil
                            ))
                        } label: {
                            Label("All Transactions", systemImage: "clock.arrow.circlepath")
                        }
                    }
                } header: {
                    BudgetDetailSectionHeader(title: "Actions", isExpanded: $actionsExpanded)
                }

                if !quickAssignSuggestions.isEmpty {
                    Section {
                        if quickAssignExpanded {
                            ForEach(quickAssignSuggestions) { suggestion in
                                Button {
                                    Task { await apply(suggestion) }
                                } label: {
                                    HStack {
                                        Text(quickAssignTitle(for: suggestion.kind))
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
                            }
                        }
                    } header: {
                        BudgetDetailSectionHeader(
                            title: isTracking ? "Quick Budget" : "Quick Assign",
                            isExpanded: $quickAssignExpanded
                        )
                    } footer: {
                        if quickAssignExpanded {
                            Text("Suggestions use this category's existing Actual history and replace the current month's amount.")
                        }
                    }
                }

                if let quickAssignError {
                    Section {
                        Text(quickAssignError)
                            .foregroundStyle(.red)
                    }
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
                    }
                }

                if !recentTransactions.isEmpty {
                    Section("Recent Activity") {
                        ForEach(recentTransactions.prefix(3)) { transaction in
                            TransactionRow(transaction: transaction)
                        }
                    }
                }
            }
            .navigationTitle(category.categoryName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await reloadSupportingDetails() }
            .sheet(isPresented: $editingBudget) {
                EditBudgetAmountSheet(category: liveCategory)
            }
            .sheet(item: $transferContext) { context in
                BudgetTransferSheet(context: context)
            }
            .sheet(isPresented: $editingNote, onDismiss: {
                Task { note = await budgetStore.fetchNote(id: category.categoryId) }
            }) {
                NoteEditorView(
                    noteId: category.categoryId,
                    title: category.categoryName,
                    note: note.text
                )
            }
        }
    }

    private func reloadSupportingDetails() async {
        async let fetchedTransactions = budgetStore.fetchCategoryTransactions(
            categoryId: category.categoryId,
            month: category.month
        )
        async let fetchedNote = budgetStore.fetchNote(id: category.categoryId)
        async let fetchedHistory = budgetStore.budgetHistory(for: category)
        recentTransactions = await fetchedTransactions
        note = await fetchedNote
        history = await fetchedHistory
    }

    private func quickAssignTitle(for kind: QuickAssignSuggestion.Kind) -> String {
        switch kind {
        case .spentLastMonth: "Spent Last Month"
        case .averageSpent: "Average Spent (\(history.count) Months)"
        case .assignedLastMonth: isTracking ? "Budgeted Last Month" : "Assigned Last Month"
        case .resetAvailable: isTracking ? "Reset Balance to Zero" : "Reset Available to Zero"
        case .setToZero: isTracking ? "Set Budget to Zero" : "Set Assigned to Zero"
        }
    }

    private func apply(_ suggestion: QuickAssignSuggestion) async {
        isApplyingSuggestion = true
        quickAssignError = nil
        do {
            try await budgetStore.setBudgetAmount(
                month: category.month,
                categoryId: category.categoryId,
                amountCents: suggestion.amount
            )
            dismiss()
        } catch {
            quickAssignError = error.localizedDescription
            isApplyingSuggestion = false
        }
    }
}

/// Tappable List section header used where a category detail can otherwise
/// become action-heavy on a phone. The state is in the accessibility label so
/// a collapsed section is distinguishable from an empty one.
struct BudgetDetailSectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(title), \(isExpanded ? "expanded" : "collapsed")")
        .accessibilityIdentifier("\(title), \(isExpanded ? "expanded" : "collapsed")")
        .accessibilityHint(isExpanded ? "Collapses this section" : "Expands this section")
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
        switch self {
        case .overspent: "Overspent"
        case .spent: "Fully spent"
        case .spending: "Partially spent"
        case .funded: "Funded"
        case .unassigned: "No money assigned"
        }
    }
}

/// Spent-vs-available bar for a budget row. Fill and color mirror the row's
/// Available amount: green while money remains, red once overspent.
struct CategoryProgressBar: View {
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
        .accessibilityLabel("\(state.statusText), spent \(Int((fraction * 100).rounded())) percent")
    }
}

/// A deliberately quiet status cue for budget rows. The category detail sheet
/// carries the full plain-language status so the main budget remains scannable.
struct CompactCategoryStatusDot: View {
    let state: CategoryProgressState

    var body: some View {
        Circle()
            .fill(state.tint)
            .frame(width: 7, height: 7)
            .accessibilityLabel(state.statusText)
    }
}

/// Edit the budgeted amount for one category-month. Saving writes through
/// the sync engine (optimistic local-first) and refreshes the month.
struct EditBudgetAmountSheet: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss
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
                    Text("Budgeted in \(MonthPicker.title(for: category.month))")
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

    var body: some View {
        Menu {
            Picker("Month", selection: $selectedMonth) {
                ForEach(monthOptions, id: \.self) { month in
                    Text(Self.title(for: month)).tag(month)
                }
            }
        } label: {
            Text(Self.title(for: selectedMonth))
                .font(.headline)
        }
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

    static func title(for month: String) -> String {
        guard let date = date(fromMonth: month) else {
            return month
        }
        return monthTitleFormatter.string(from: date)
    }

    static func date(fromMonth month: String) -> Date? {
        let parts = month.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]),
              let monthNumber = Int(parts[1]) else {
            return nil
        }
        var components = DateComponents()
        components.year = year
        components.month = monthNumber
        components.day = 1
        return Calendar.current.date(from: components)
    }
}

#Preview {
    BudgetView()
        .environmentObject(BudgetStore.previewInstance())
}
