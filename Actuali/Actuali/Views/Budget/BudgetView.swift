import SwiftUI

// MARK: - Formatters

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

private let monthShortTitleFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM yyyy"
    return formatter
}()

// MARK: - Shared Column Metrics

enum BudgetColumn {
    static let width: CGFloat = 70
    static let spacing: CGFloat = 4

    static func text(_ cents: Int, wholeUnits: Bool = false) -> String {
        (Double(cents) / 100.0).formatted(
            .number.precision(.fractionLength(wholeUnits ? 0 : 2)))
    }
}

private extension BudgetStore {
    func displayBudgetCell(_ cents: Int) -> String {
        hideBalances ? Self.hiddenBalanceText : BudgetColumn.text(cents, wholeUnits: hideDecimalPlaces)
    }
}

// MARK: - BudgetView

struct BudgetView: View {
    nonisolated static let incomeGroupCollapseID = "__income_group__"

    nonisolated static func displayedGroupIDs(
        groupIDs: [String],
        hasIncome: Bool
    ) -> Set<String> {
        var ids = Set(groupIDs)
        if hasIncome { ids.insert(incomeGroupCollapseID) }
        return ids
    }

    @EnvironmentObject var budgetStore: BudgetStore
    @State private var selectedMonth = currentMonthString()
    @State private var editingCategory: CategoryBudget?
    @State private var selectedCategory: CategoryBudget?
    @State private var transferContext: BudgetTransferContext?
    @State private var transactionsDestination: CategoryTransactionsDestination?
    @State private var newBudgetItem: NewBudgetItem?
    @State private var categoryFilter: BudgetCategoryFilter = .all
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
                            description: Text("You're connected. Choose a budget in More → Connection & Data to load it here.")
                        )
                    } else {
                        ContentUnavailableView(
                            "No Budget Loaded",
                            systemImage: "chart.pie",
                            description: Text("Go to More → Connection & Data to connect to your Actual Budget server")
                        )
                    }
                }
            }
            .navigationTitle("Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { budgetToolbar }
            .onChange(of: selectedMonth) { _, newMonth in
                Task { await budgetStore.fetchBudgetMonth(newMonth) }
            }
            .onChange(of: budgetStore.showBudgetCheckInStrip) { _, isShown in
                if !isShown { categoryFilter = .all }
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
            .sheet(item: $newBudgetItem) { item in
                switch item {
                case .category: NewCategorySheet(groupId: firstSelectableGroupId ?? "")
                case .group: NewCategoryGroupSheet()
                }
            }
            .navigationDestination(item: $transactionsDestination) { destination in
                CategoryTransactionsView(destination: destination)
            }
            .overlay {
                if budgetStore.isLoading { ProgressView() }
            }
        }
        .initialSyncBanner()
    }

    // MARK: - Group Sections

    @ViewBuilder
    private func groupSection(_ group: CategoryGroupSection) -> some View {
        let isCollapsed = collapsedGroups.contains(group.id)

        if budgetStore.budgetDisplayStyle == .clean {
            // Clean style: section header with the original ellipsis menu
            Section {
                if !isCollapsed {
                    ForEach(group.categories) { category in
                        CleanCategoryBudgetRow(
                            category: category,
                            isHidden: category.hidden,
                            isDimmed: category.isEffectivelyHidden,
                            onSetHidden: { setCategoryHidden(category.categoryId, hidden: $0) },
                            onShowDetails: { selectedCategory = $0 },
                            onEditBudget: { editingCategory = $0 },
                            onShowTransactions: showTransactions,
                            onMoveMoney: moveMoney
                        )
                    }
                }
            } header: {
                BudgetGroupHeader(
                    name: group.name,
                    isCollapsed: isCollapsed,
                    isDimmed: group.isHidden,
                    onSetHidden: { setCategoryGroupHidden(group.id, hidden: $0) },
                    onToggleCollapse: { toggleCollapsed(group.id) }
                )
                .textCase(nil)
            }
        } else {
            // Detailed style: header row inside the section with swipe-to-hide
            Section {
                BudgetGroupHeader(
                    name: group.name,
                    isCollapsed: isCollapsed,
                    isDimmed: group.isHidden,
                    totals: budgetStore.showGroupTotals ? group.totals : nil,
                    onToggleCollapse: { toggleCollapsed(group.id) },
                    reservesTwoLines: true
                )
                .listRowBackground(Color(.tertiarySystemFill))
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 16))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    hideGroupButton(group)
                }
                if !isCollapsed {
                    ForEach(group.categories) { category in
                        CategoryBudgetRow(
                            category: category,
                            isHidden: category.hidden,
                            isDimmed: category.isEffectivelyHidden,
                            onSetHidden: { setCategoryHidden(category.categoryId, hidden: $0) },
                            addsGroupBottomPadding: category.id == group.categories.last?.id,
                            onShowDetails: { selectedCategory = $0 },
                            onEditBudget: { editingCategory = $0 },
                            onShowTransactions: showTransactions,
                            onMoveMoney: moveMoney
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func incomeSection(_ budget: BudgetMonth) -> some View {
        let isCollapsed = collapsedGroups.contains(Self.incomeGroupCollapseID)
        let group = budgetStore.categoryGroups.first(where: \.isIncome)
        let categories = displayedIncomeCategories(in: budget)
        let name = group?.name ?? categories.first?.groupName ?? "Income"

        if budgetStore.budgetDisplayStyle == .clean {
            Section {
                if !isCollapsed {
                    ForEach(categories) { income in
                        IncomeCategoryRow(
                            income: income,
                            isHidden: income.hidden,
                            isDimmed: income.isEffectivelyHidden,
                            onSetHidden: { setCategoryHidden(income.categoryId, hidden: $0) },
                            showsBudgeted: budget.toBudget == nil,
                            isDetailed: false,
                            onShowTransactions: showTransactions
                        )
                    }
                }
            } header: {
                BudgetGroupHeader(
                    name: name,
                    isCollapsed: isCollapsed,
                    isDimmed: group?.hidden == true,
                    onSetHidden: group.map { _ in { setCategoryGroupHidden(group!.id, hidden: $0) } },
                    receivedTotal: budget.totalIncome,
                    onToggleCollapse: { toggleCollapsed(Self.incomeGroupCollapseID) }
                )
                .textCase(nil)
            }
        } else {
            Section {
                BudgetGroupHeader(
                    name: name,
                    isCollapsed: isCollapsed,
                    isDimmed: group?.hidden == true,
                    receivedTotal: budget.totalIncome,
                    onToggleCollapse: { toggleCollapsed(Self.incomeGroupCollapseID) },
                    usesTableNumberFormat: true,
                    reservesTwoLines: true
                )
                .listRowBackground(Color(.tertiarySystemFill))
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 16))
                if !isCollapsed {
                    ForEach(categories) { income in
                        IncomeCategoryRow(
                            income: income,
                            isHidden: income.hidden,
                            isDimmed: income.isEffectivelyHidden,
                            onSetHidden: { setCategoryHidden(income.categoryId, hidden: $0) },
                            showsBudgeted: budget.toBudget == nil,
                            isDetailed: true,
                            onShowTransactions: showTransactions
                        )
                    }
                }
            }
        }
    }

    // MARK: - Shared Swipe Action (detailed style only)

    @ViewBuilder
    private func hideGroupButton(_ group: CategoryGroupSection) -> some View {
        Button {
            setCategoryGroupHidden(group.id, hidden: !group.isHidden)
        } label: {
            Label(group.isHidden ? "Show" : "Hide",
                  systemImage: group.isHidden ? "eye" : "eye.slash")
        }
        .tint(group.isHidden ? .accentColor : .secondary)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var budgetToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
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

        if budgetStore.currentBudgetMonth != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        newBudgetItem = .category
                    } label: {
                        Label("New Category", systemImage: "tag")
                    }
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
            let hasBudget = budgetStore.currentBudgetMonth != nil
            BudgetOptionsMenu(
                expandAllGroups: hasBudget ? { expandAllGroups() } : nil,
                collapseAllGroups: hasBudget ? { collapseAllGroups() } : nil
            )
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private func loadedBudgetContent(_ budget: BudgetMonth) -> some View {
        VStack(spacing: 0) {
            // Summary card
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
            .padding(.horizontal, 4)
            .padding(.top, 8)
            .padding(.bottom, 8)

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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                }
                .accessibilityIdentifier("budgetUncategorized")
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
            }

            if budgetStore.showBudgetCheckInStrip {
                BudgetCheckInStrip(budget: budget, selection: $categoryFilter)
                    .padding(.bottom, 8)
            }

            List {
                if categoryFilter != .all, groupedCategories.isEmpty {
                    ContentUnavailableView {
                        Label("No Matching Categories", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("Try another category filter.")
                    } actions: {
                        Button("Show All Categories") { categoryFilter = .all }
                    }
                }

                ForEach(groupedCategories, id: \.id) { group in
                    groupSection(group)
                }

                if categoryFilter == .all, !displayedIncomeCategories(in: budget).isEmpty {
                    incomeSection(budget)
                }
            }
            .animation(AppAnimation.disclosure, value: collapsedGroupsStorage)
            .listSectionSpacing(budgetStore.budgetDisplayStyle == .clean ? .default : .custom(14))
            .refreshable { await budgetStore.sync() }
            .contentMargins(.horizontal, 4, for: .scrollContent)
            .contentMargins(.top, budgetStore.budgetDisplayStyle == .clean ? 20 : 16, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, 32)
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
        .readableWidth()
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    // MARK: - Actions

    private func moveMoney(_ category: CategoryBudget) {
        guard let budget = budgetStore.currentBudgetMonth else { return }
        transferContext = BudgetTransferContext(category: category, budget: budget)
    }

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
                try await budgetStore.setCategoryHidden(id: id, hidden: hidden, month: selectedMonth)
            } catch {
                budgetStore.error = error.localizedDescription
            }
        }
    }

    private func setCategoryGroupHidden(_ id: String, hidden: Bool) {
        Task {
            do {
                try await budgetStore.setCategoryGroupHidden(id: id, hidden: hidden, month: selectedMonth)
            } catch {
                budgetStore.error = error.localizedDescription
            }
        }
    }

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

    // MARK: - Grouped Data

    struct CategoryGroupSection {
        let id: String
        let name: String
        let isHidden: Bool
        let categories: [CategoryBudget]
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
                let base = categoryFilter == .all
                    ? budgetStore.visibleCategoryBudgets(items)
                    : items.filter(categoryFilter.includes)
                let visible = base.sorted { $0.categorySortOrder < $1.categorySortOrder }
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
        return sections.sorted { $0.0 < $1.0 }.map(\.1)
    }

    static func currentMonthString() -> String {
        yearMonthFormatter.string(from: Date())
    }

    static func shiftMonth(_ month: String, by offset: Int) -> String {
        BudgetStore.shiftBudgetMonth(month, by: offset) ?? month
    }
}

// MARK: - Reusable Views

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

struct BudgetCheckInStrip: View {
    let budget: BudgetMonth
    @Binding var selection: BudgetCategoryFilter

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(BudgetCategoryFilter.allCases) { filter in
                    Button {
                        selection = filter
                    } label: {
                        Text(title(for: filter))
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
                    .accessibilityLabel("Show \(title(for: filter)) categories")
                    .accessibilityIdentifier("budgetFilter-\(filter.rawValue)")
                    .accessibilityAddTraits(selection == filter ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, 4, for: .scrollContent)
    }

    private func title(for filter: BudgetCategoryFilter) -> String {
        switch filter {
        case .all: "All"
        case .needsAttention: "Needs Attention \(count(for: filter))"
        case .overspent: "\(budget.isTrackingBudget ? "Over Budget" : "Overspent") \(count(for: filter))"
        case .unassigned: "\(budget.isTrackingBudget ? "No Budget" : "Not Funded") \(count(for: filter))"
        case .approachingLimit: "\(budget.isTrackingBudget ? "Near Budget" : "Almost Spent") \(count(for: filter))"
        case .onTrack: "\(budget.isTrackingBudget ? "Within Budget" : "On Track") \(count(for: filter))"
        }
    }

    private func count(for filter: BudgetCategoryFilter) -> Int {
        budget.categoryBudgets.count(where: filter.includes)
    }
}

struct CategoryBudgetRow: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let category: CategoryBudget
    var isHidden = false
    var isDimmed = false
    var onSetHidden: ((Bool) -> Void)?
    var addsGroupBottomPadding = false
    var onShowDetails: (CategoryBudget) -> Void = { _ in }
    var onEditBudget: (CategoryBudget) -> Void = { _ in }
    var onShowTransactions: (CategoryBudget, String?) -> Void = { _, _ in }
    var onMoveMoney: (CategoryBudget) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: BudgetColumn.spacing) {
                Button {
                    onShowDetails(category)
                } label: {
                    HStack(spacing: 5) {
                        if budgetStore.showCategoryStatusDots {
                            CompactCategoryStatusDot(state: category.progressState)
                        }
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
        .listRowInsets(EdgeInsets(
            top: 4,
            leading: 12,
            bottom: addsGroupBottomPadding && budgetStore.showBudgetProgressBars
                && category.showsProgressBar ? 10 : 4,
            trailing: 16
        ))
        .opacity(isDimmed ? 0.5 : 1)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let onSetHidden {
                Button {
                    onSetHidden(!isHidden)
                } label: {
                    Label(isHidden ? "Show" : "Hide", systemImage: isHidden ? "eye" : "eye.slash")
                }
                .tint(isHidden ? .accentColor : .secondary)
            }
        }
    }
}

struct CleanCategoryBudgetRow: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let category: CategoryBudget
    var isHidden = false
    var isDimmed = false
    var onSetHidden: ((Bool) -> Void)?
    var onShowDetails: (CategoryBudget) -> Void = { _ in }
    var onEditBudget: (CategoryBudget) -> Void = { _ in }
    var onShowTransactions: (CategoryBudget, String?) -> Void = { _, _ in }
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
                .accessibilityLabel("Details for \(category.categoryName)")
                Spacer()
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
        .opacity(isDimmed ? 0.5 : 1)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let onSetHidden {
                Button {
                    onSetHidden(!isHidden)
                } label: {
                    Label(isHidden ? "Show" : "Hide", systemImage: isHidden ? "eye" : "eye.slash")
                }
                .tint(isHidden ? .accentColor : .secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

@MainActor private func isPastMonth(_ month: String) -> Bool {
    month < BudgetView.currentMonthString()
}

@MainActor private func trackingSavings(_ budget: BudgetMonth) -> Int {
    isPastMonth(budget.month) ? budget.savedActual : budget.projectedSavings
}

@MainActor private func trackingSavingsLabel(_ budget: BudgetMonth) -> String {
    isPastMonth(budget.month) ? "Saved" : "Projected"
}

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

struct TableBudgetSummary: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let budget: BudgetMonth

    var body: some View {
        HStack(alignment: .top, spacing: BudgetColumn.spacing) {
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

private struct CaptionedAmountPill: View {
    let label: String
    let text: String
    var color: Color = .primary
    var dimmed = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            BudgetAmountPill(text: text, color: color, dimmed: dimmed)
        }
        .frame(width: BudgetColumn.width, alignment: .trailing)
    }
}

struct BudgetGroupHeader: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let name: String
    let isCollapsed: Bool
    var isDimmed = false
    var onSetHidden: ((Bool) -> Void)?
    var totals: CategoryGroupTotals?
    var receivedTotal: Int? = nil
    let onToggleCollapse: () -> Void
    var usesTableNumberFormat = false
    var reservesTwoLines = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleCollapse) {
                HStack(alignment: .top, spacing: BudgetColumn.spacing) {
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
                    }
                    Spacer(minLength: 4)
                    if let totals {
                        CaptionedAmountPill(
                            label: "Budgeted",
                            text: budgetStore.displayBudgetCell(totals.budgeted),
                            dimmed: totals.budgeted == 0
                        )
                        CaptionedAmountPill(
                            label: "Spent",
                            text: budgetStore.displayBudgetCell(totals.spent),
                            dimmed: totals.spent == 0
                        )
                        CaptionedAmountPill(
                            label: "Balance",
                            text: budgetStore.displayBudgetCell(totals.balance),
                            color: totals.balance < 0
                                ? .red
                                : (totals.balance == 0 ? .secondary : .green)
                        )
                    } else if let receivedTotal {
                        Text("Received \(receivedText(receivedTotal))")
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
            .accessibilityHint("Toggles the group's categories")

            if let onSetHidden {
                Menu {
                    Button {
                        onSetHidden(!isDimmed)
                    } label: {
                        Label(
                            isDimmed ? "Show Group" : "Hide Group",
                            systemImage: isDimmed ? "eye" : "eye.slash"
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(minWidth: 32, minHeight: 44)
                }
                .accessibilityLabel("Options for \(name)")
            }
        }
        .opacity(isDimmed ? 0.5 : 1)
    }

    private var accessibilityLabel: String {
        let state = isCollapsed ? "collapsed" : "expanded"
        if let receivedTotal {
            return "\(name), \(state), received \(budgetStore.displayBalance(receivedTotal))"
        }
        guard let totals else { return "\(name), \(state)" }
        return Self.totalsAccessibilityLabel(
            name: name,
            isCollapsed: isCollapsed,
            budgeted: budgetStore.displayBalance(totals.budgeted),
            spent: budgetStore.displayBalance(totals.spent),
            balance: budgetStore.displayBalance(totals.balance)
        )
    }

    nonisolated static func totalsAccessibilityLabel(
        name: String,
        isCollapsed: Bool,
        budgeted: String,
        spent: String,
        balance: String
    ) -> String {
        "\(name), \(isCollapsed ? "collapsed" : "expanded"), budgeted \(budgeted), spent \(spent), balance \(balance)"
    }

    private func receivedText(_ amount: Int) -> String {
        usesTableNumberFormat
            ? budgetStore.displayBudgetCell(amount)
            : budgetStore.displayBalance(amount)
    }
}

struct IncomeCategoryRow: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let income: IncomeCategory
    var isHidden = false
    var isDimmed = false
    var onSetHidden: ((Bool) -> Void)?
    var showsBudgeted = false
    var isDetailed = false
    var onShowTransactions: (IncomeCategory, String?) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: isDetailed ? BudgetColumn.spacing : 8) {
                Button {
                    onShowTransactions(income, nil)
                } label: {
                    TwoLineName(
                        text: income.categoryName,
                        font: isDetailed ? .subheadline : .body,
                        minimumScaleFactor: 0.85
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("All transactions for \(income.categoryName)")

                Spacer()

                Button { onShowTransactions(income, income.month) } label: {
                    if isDetailed {
                        BudgetAmountPill(
                            text: budgetStore.displayBudgetCell(income.received),
                            color: income.received > 0 ? .green : .secondary
                        )
                    } else {
                        Text(budgetStore.displayBalance(income.received))
                            .foregroundColor(income.received > 0 ? .green : .secondary)
                    }
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
        .listRowInsets(EdgeInsets(
            top: 4,
            leading: isDetailed ? 12 : 16,
            bottom: 4,
            trailing: 16
        ))
        .opacity(isDimmed ? 0.5 : 1)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let onSetHidden {
                Button {
                    onSetHidden(!isHidden)
                } label: {
                    Label(isHidden ? "Show" : "Hide", systemImage: isHidden ? "eye" : "eye.slash")
                }
                .tint(isHidden ? .accentColor : .secondary)
            }
        }
    }
}

// MARK: - Category Detail Sheet

struct CategoryBudgetDetailSheet: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let category: CategoryBudget

    @State private var name: String
    @State private var editingNote = false
    @State private var note: EntityNote = .unsupported
    @State private var history: [CategoryBudget] = []
    @State private var isSavingName = false
    @State private var isApplyingSuggestion = false
    @State private var errorMessage: String?

    init(category: CategoryBudget) {
        self.category = category
        _name = State(initialValue: category.categoryName)
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

                Section(
                    content: {
                        LabeledContent(MonthPicker.title(for: category.month)) {
                            Text(budgetStore.displayBalance(category.budgeted))
                                .monospacedDigit()
                        }

                        if quickAssignSuggestions.isEmpty {
                            Text("No suggestions available")
                                .foregroundStyle(.secondary)
                        } else {
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
                    },
                    header: {
                        Text(isTracking ? "Quick Budget" : "Quick Assign")
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
            .disabled(isSavingName)
            .interactiveDismissDisabled(isSavingName)
        }
    }

    private func reloadSupportingDetails() async {
        async let fetchedNote = budgetStore.fetchNote(id: category.categoryId)
        async let fetchedHistory = budgetStore.budgetHistory(for: category)
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

// MARK: - Status & Progress Views

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
        .animation(AppAnimation.amount, value: fraction)
        .accessibilityElement()
        .accessibilityLabel("\(state.statusText), spent \(Int((fraction * 100).rounded())) percent")
    }
}

struct CompactCategoryStatusDot: View {
    let state: CategoryProgressState

    var body: some View {
        Circle()
            .fill(state.tint)
            .frame(width: 7, height: 7)
            .accessibilityLabel(state.statusText)
            .accessibilityIdentifier("categoryStatusDot")
    }
}

// MARK: - Edit Budget Amount Sheet

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

// MARK: - Month Picker

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
            Text(Self.shortTitle(for: selectedMonth))
                .font(.headline)
                .lineLimit(1)
        }
        .accessibilityLabel(Self.title(for: selectedMonth))
    }

    private var monthOptions: [String] {
        let current = BudgetView.currentMonthString()
        var months = (-12...1).map { BudgetView.shiftMonth(current, by: $0) }
        if !months.contains(selectedMonth) {
            months.append(selectedMonth)
            months.sort()
        }
        return months.reversed()
    }

    nonisolated static func title(for month: String) -> String {
        guard let date = date(fromMonth: month) else { return month }
        return monthTitleFormatter.string(from: date)
    }

    nonisolated static func shortTitle(for month: String) -> String {
        guard let date = date(fromMonth: month) else { return month }
        return monthShortTitleFormatter.string(from: date)
    }

    nonisolated static func date(fromMonth month: String) -> Date? {
        let parts = month.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]),
              let monthNumber = Int(parts[1]) else { return nil }
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
