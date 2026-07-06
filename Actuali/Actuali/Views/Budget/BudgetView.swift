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

struct BudgetView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @State private var selectedMonth = currentMonthString()

    var body: some View {
        NavigationStack {
            Group {
                if let budget = budgetStore.currentBudgetMonth {
                    List {
                        Section {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("Budgeted")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(budgetStore.formatCurrency(budget.totalBudgeted))
                                        .font(.headline)
                                }
                                Spacer()
                                VStack(alignment: .center) {
                                    Text("Spent")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(budgetStore.formatCurrency(abs(budget.totalSpent)))
                                        .font(.headline)
                                }
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text("Available")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(budgetStore.formatCurrency(budget.totalAvailable))
                                        .font(.headline)
                                        .foregroundColor(budget.totalAvailable >= 0 ? .green : .red)
                                }
                            }
                            .padding(.vertical, 4)
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

                        ForEach(groupedCategories, id: \.0) { groupName, categories in
                            Section(groupName) {
                                ForEach(categories) { category in
                                    CategoryBudgetRow(category: category)
                                }
                            }
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
                } else if !budgetStore.isLoading {
                    ContentUnavailableView(
                        "No Budget Loaded",
                        systemImage: "chart.pie",
                        description: Text("Go to Settings to connect to your Actual Budget server")
                    )
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
                await budgetStore.fetchBudgetMonth(selectedMonth)
            }
            .overlay {
                if budgetStore.isLoading {
                    ProgressView()
                }
            }
        }
    }

    var groupedCategories: [(String, [CategoryBudget])] {
        guard let budget = budgetStore.currentBudgetMonth else { return [] }
        let byGroup = Dictionary(grouping: budget.categoryBudgets, by: { $0.groupId })
        return byGroup
            .compactMap { _, items -> (Double, String, [CategoryBudget])? in
                guard let first = items.first else { return nil }
                let sorted = items.sorted { $0.categorySortOrder < $1.categorySortOrder }
                return (first.groupSortOrder, first.groupName, sorted)
            }
            .sorted { $0.0 < $1.0 }
            .map { ($0.1, $0.2) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(category.categoryName)
                    .font(.body)
                Spacer()
                Text(budgetStore.formatCurrency(category.available))
                    .foregroundColor(category.isOverspent ? .red : .green)
            }
            HStack {
                Text("Budgeted: \(budgetStore.formatCurrency(category.budgeted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Spent: \(budgetStore.formatCurrency(abs(category.spent)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
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
