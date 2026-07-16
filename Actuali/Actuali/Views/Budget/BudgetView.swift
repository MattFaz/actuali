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
    static let spacing: CGFloat = 6

    /// Cell text for the budget table: a plain grouped number without the
    /// currency symbol, like the PWA's budget table — "USD 1,850.00" in
    /// every cell would drown the category names on a phone.
    static func text(_ cents: Int) -> String {
        (Double(cents) / 100.0).formatted(.number.precision(.fractionLength(2)))
    }
}

struct BudgetView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @State private var selectedMonth = currentMonthString()
    @State private var editingCategory: CategoryBudget?
    @State private var transactionsDestination: CategoryTransactionsDestination?
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

    var body: some View {
        NavigationStack {
            Group {
                if let budget = budgetStore.currentBudgetMonth {
                    List {
                        // PWA-style summary bar: unallocated funds lead, and
                        // the three captioned columns double as the column
                        // headers for the table below.
                        Section {
                            HStack(alignment: .top, spacing: BudgetColumn.spacing) {
                                // Envelope budgets lead with unallocated funds;
                                // tracking budgets have no to-budget concept, so
                                // lead with income received instead.
                                if let toBudget = budget.toBudget {
                                    SummaryStat(
                                        label: "To Budget",
                                        value: BudgetColumn.text(toBudget),
                                        valueColor: toBudget >= 0 ? .green : .red
                                    )
                                } else {
                                    SummaryStat(
                                        label: "Income",
                                        value: BudgetColumn.text(budget.totalIncome)
                                    )
                                }
                                Spacer(minLength: 4)
                                SummaryColumn(
                                    label: "Budgeted",
                                    value: BudgetColumn.text(budget.totalBudgeted)
                                )
                                SummaryColumn(
                                    label: "Spent",
                                    value: BudgetColumn.text(budget.totalOutflow)
                                )
                                SummaryColumn(
                                    label: "Balance",
                                    value: BudgetColumn.text(budget.totalAvailable),
                                    valueColor: budget.totalAvailable >= 0 ? .green : .red
                                )
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        }

                        if budgetStore.uncategorizedCount > 0 {
                            Section {
                                NavigationLink {
                                    UncategorizedTransactionsView()
                                } label: {
                                    Label {
                                        Text("^[\(budgetStore.uncategorizedCount) Uncategorized Transaction](inflect: true)")
                                    } icon: {
                                        Image(systemName: "questionmark.circle.fill")
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                        }

                        ForEach(groupedCategories, id: \.id) { group in
                            let isCollapsed = collapsedGroups.contains(group.id)
                            // The group row lives inside the card (first row,
                            // tinted) like the PWA's table, so its totals
                            // share the exact column grid of the rows below.
                            Section {
                                BudgetGroupHeader(
                                    name: group.name,
                                    isCollapsed: isCollapsed,
                                    onToggleCollapse: { toggleCollapsed(group.id) }
                                )
                                .listRowBackground(Color(.tertiarySystemFill))
                                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 16))
                                if !isCollapsed {
                                    ForEach(group.categories) { category in
                                        CategoryBudgetRow(
                                            category: category,
                                            onEditBudget: { editingCategory = $0 },
                                            // Name shows all time, Spent shows the
                                            // displayed month (GH #56).
                                            onShowTransactions: { category, month in
                                                transactionsDestination = CategoryTransactionsDestination(
                                                    categoryId: category.categoryId,
                                                    categoryName: category.categoryName,
                                                    month: month
                                                )
                                            }
                                        )
                                    }
                                }
                            }
                        }

                        // Income group last, matching the bottom of the web
                        // UI's budget table.
                        if !budget.incomeCategories.isEmpty {
                            Section {
                                ForEach(budget.incomeCategories) { income in
                                    IncomeCategoryRow(
                                        income: income,
                                        // Only tracking budgets budget income;
                                        // envelope budgets just receive it.
                                        showsBudgeted: budget.toBudget == nil
                                    )
                                }
                            } header: {
                                HStack {
                                    Text(budget.incomeCategories.first?.groupName ?? "Income")
                                    Spacer()
                                    Text("Received \(budgetStore.formatCurrency(budget.totalIncome))")
                                }
                            }
                        }
                    }
                    .listSectionSpacing(14)
                    // Let short rows (group headers) sit below the stock
                    // 44 pt minimum; tap targets stay fine because the whole
                    // row is the button.
                    .environment(\.defaultMinListRowHeight, 32)
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        selectedMonth = Self.shiftMonth(selectedMonth, by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Previous month")
                }
                ToolbarItem(placement: .principal) {
                    MonthPicker(selectedMonth: $selectedMonth)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        selectedMonth = Self.shiftMonth(selectedMonth, by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .accessibilityLabel("Next month")
                }
            }
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
            .navigationDestination(item: $transactionsDestination) { destination in
                CategoryTransactionsView(destination: destination)
            }
            .overlay {
                if budgetStore.isLoading {
                    ProgressView()
                }
            }
        }
    }

    struct CategoryGroupSection {
        let id: String
        let name: String
        let categories: [CategoryBudget]
    }

    var groupedCategories: [CategoryGroupSection] {
        guard let budget = budgetStore.currentBudgetMonth else { return [] }
        let byGroup = Dictionary(grouping: budget.categoryBudgets, by: { $0.groupId })
        return byGroup
            .compactMap { groupId, items -> (Double, CategoryGroupSection)? in
                guard let first = items.first else { return nil }
                let sorted = items.sorted { $0.categorySortOrder < $1.categorySortOrder }
                return (
                    first.groupSortOrder,
                    CategoryGroupSection(id: groupId, name: first.groupName, categories: sorted)
                )
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }

    static func currentMonthString() -> String {
        yearMonthFormatter.string(from: Date())
    }

    static func shiftMonth(_ month: String, by offset: Int) -> String {
        let parts = month.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]),
              let m = Int(parts[1]) else { return month }
        var components = DateComponents()
        components.year = year
        components.month = m
        components.day = 1
        let calendar = Calendar.current
        guard let date = calendar.date(from: components),
              let shifted = calendar.date(byAdding: .month, value: offset, to: date) else {
            return month
        }
        return yearMonthFormatter.string(from: shifted)
    }
}

struct CategoryBudgetRow: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let category: CategoryBudget
    var onEditBudget: (CategoryBudget) -> Void = { _ in }
    /// Push the category's transactions: month narrows to one "yyyy-MM",
    /// nil means all time (GH #56).
    var onShowTransactions: (CategoryBudget, String?) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // One PWA-style table line: name, then the Budgeted/Spent/Balance
            // pills in their fixed columns. Each element keeps its own tap
            // action (our enhancement over the PWA's read-only cells).
            HStack(spacing: BudgetColumn.spacing) {
                Button {
                    onShowTransactions(category, nil)
                } label: {
                    Text(category.categoryName)
                        .font(.subheadline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("All transactions for \(category.categoryName)")
                Spacer(minLength: 4)
                Button {
                    onEditBudget(category)
                } label: {
                    BudgetAmountPill(
                        text: BudgetColumn.text(category.budgeted),
                        dimmed: category.budgeted == 0
                    )
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Edit budgeted amount for \(category.categoryName)")
                Button {
                    onShowTransactions(category, category.month)
                } label: {
                    BudgetAmountPill(
                        text: BudgetColumn.text(category.spent),
                        dimmed: category.spent == 0
                    )
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Transactions for \(category.categoryName) in \(MonthPicker.title(for: category.month))")
                BudgetAmountPill(
                    text: BudgetColumn.text(category.available),
                    color: category.isOverspent ? .red : (category.available == 0 ? .secondary : .green)
                )
            }
            if budgetStore.showBudgetProgressBars, category.showsProgressBar {
                CategoryProgressBar(
                    fraction: category.progressFraction,
                    isOverspent: category.isOverspent
                )
            }
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}

/// The leading figure in the summary bar (To Budget / Income).
struct SummaryStat: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        VStack(alignment: .leading) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .foregroundColor(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
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
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(width: BudgetColumn.width, alignment: .trailing)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemFill).opacity(0.6))
            )
    }
}

/// Group header row: collapse control and group name, like the PWA's group
/// rows but without the totals.
struct BudgetGroupHeader: View {
    let name: String
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void

    var body: some View {
        Button(action: onToggleCollapse) {
            HStack(spacing: BudgetColumn.spacing) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(isCollapsed ? "collapsed" : "expanded")")
        .accessibilityHint("Toggles the group's categories")
    }
}

/// One income category: name and the amount received this month. Tracking
/// budgets can budget income, so they also get a "Budgeted" caption.
struct IncomeCategoryRow: View {
    @EnvironmentObject var budgetStore: BudgetStore
    let income: IncomeCategory
    var showsBudgeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(income.categoryName)
                    .font(.body)
                Spacer()
                Text(budgetStore.formatCurrency(income.received))
                    .foregroundColor(income.received > 0 ? .green : .secondary)
            }
            if showsBudgeted {
                Text("Budgeted: \(budgetStore.formatCurrency(income.budgeted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }
}

/// Spent-vs-available bar for a budget row. Fill and color mirror the row's
/// Available amount: green while money remains, red once overspent.
struct CategoryProgressBar: View {
    let fraction: Double
    let isOverspent: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.systemFill))
                Capsule()
                    .fill(isOverspent ? Color.red : Color.green)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 5)
        .accessibilityElement()
        .accessibilityLabel("Spent \(Int((fraction * 100).rounded())) percent of available")
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
                    AmountInputField(text: $amountText)
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
                    from: amountText.isEmpty ? "0" : amountText
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
