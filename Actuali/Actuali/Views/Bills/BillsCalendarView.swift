import SwiftUI

/// A dedicated calendar dashboard for scheduled transactions and credit card bill cycles.
struct BillsCalendarView: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    @State private var selectedYear: Int = DayDate.today().year
    @State private var selectedMonth: Int = DayDate.today().month
    @State private var tabMode: BillsTabMode = .recurring
    @State private var activeFilter: BillFilter = .upcoming
    @State private var selectedDate: DayDate? = nil

    @State private var editingSchedule: ScheduleSummary? = nil
    @State private var isAddingSchedule: Bool = false
    @State private var showingCreditCardsSetup: Bool = false
    @State private var actionError: String? = nil
    @State private var pendingDelete: ScheduleSummary? = nil

    private var today: DayDate { DayDate.today() }

    private var monthKey: String {
        String(format: "%04d-%02d", selectedYear, selectedMonth)
    }

    private var monthTitle: String {
        MonthPicker.title(for: monthKey)
    }

    private func shiftMonth(by delta: Int) {
        let currentDay = DayDate(year: selectedYear, month: selectedMonth, day: 1)
        let shifted = currentDay.adding(months: delta)
        selectedYear = shifted.year
        selectedMonth = shifted.month
        selectedDate = nil
    }

    // MARK: - Computed Items

    private var rawItems: [BillCalendarItem] {
        switch tabMode {
        case .recurring:
            return BillsCalendarEngine.itemsForSchedules(
                schedules: budgetStore.schedules,
                statuses: budgetStore.scheduleStatuses,
                accounts: budgetStore.accounts,
                payees: budgetStore.payees,
                categoryGroups: budgetStore.categoryGroups,
                year: selectedYear,
                month: selectedMonth,
                today: today
            )
        case .cardBills:
            let cycles = Dictionary(uniqueKeysWithValues: budgetStore.accounts.compactMap { acc -> (String, CreditCardCycle)? in
                guard let cycle = budgetStore.activeCreditCardCycle(for: acc.id) else { return nil }
                return (acc.id, cycle)
            })
            return BillsCalendarEngine.itemsForCreditCards(
                accounts: budgetStore.accounts,
                cycles: cycles,
                year: selectedYear,
                month: selectedMonth,
                today: today
            )
        }
    }

    private var itemsByDate: [DayDate: [BillCalendarItem]] {
        Dictionary(grouping: rawItems, by: \.date)
    }

    private var summary: BillsMonthSummary {
        BillsCalendarEngine.summarize(items: rawItems)
    }

    private var filteredItems: [BillCalendarItem] {
        BillsCalendarEngine.filter(items: rawItems, filter: activeFilter, selectedDate: selectedDate)
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        Task {
            do { try await operation() }
            catch { actionError = error.localizedDescription }
        }
    }

    // MARK: - View Body

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Mode switcher (Recurring vs Card Bills)
                Picker("Mode", selection: $tabMode) {
                    ForEach(BillsTabMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChange(of: tabMode) { _, _ in
                    selectedDate = nil
                }

                // Month Navigation & Cleared Counter
                HStack {
                    HStack(spacing: 8) {
                        Button {
                            shiftMonth(by: -1)
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                        .accessibilityLabel("Previous Month")

                        Text(monthTitle)
                            .font(.title3.weight(.bold))

                        Button {
                            shiftMonth(by: 1)
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                        .accessibilityLabel("Next Month")
                    }

                    Spacer()

                    if summary.totalCount > 0 {
                        Text("Cleared \(summary.clearedCount) / \(summary.totalCount)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)

                // Calendar Grid
                calendarGridSection
                    .padding(.horizontal)

                // Summary Stats Strip
                summaryStripSection
                    .padding(.horizontal)

                // Filter Pills
                filterPillsSection
                    .padding(.horizontal)

                // Cards List Section
                cardsListSection
                    .padding(.horizontal)
            }
            .padding(.vertical, 8)
        }
        .navigationTitle("Bills")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if tabMode == .recurring {
                        isAddingSchedule = true
                    } else {
                        showingCreditCardsSetup = true
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(tabMode == .recurring ? "Add Schedule" : "Configure Cards")
            }
        }
        .refreshable {
            await budgetStore.loadSchedules()
        }
        .sheet(isPresented: $isAddingSchedule) {
            NavigationStack {
                ScheduleEditView(budgetStore: budgetStore)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { isAddingSchedule = false }
                        }
                    }
            }
        }
        .sheet(item: $editingSchedule) { schedule in
            NavigationStack {
                ScheduleEditView(editing: schedule, budgetStore: budgetStore)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { editingSchedule = nil }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingCreditCardsSetup) {
            NavigationStack {
                CreditCardsSettingsView()
                    .environmentObject(budgetStore)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingCreditCardsSetup = false }
                        }
                    }
            }
        }
        .confirmationDialog(
            pendingDelete.map { _ in "Delete this schedule?" } ?? "",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Schedule", role: .destructive) {
                guard let schedule = pendingDelete else { return }
                run { try await budgetStore.deleteSchedule(schedule) }
            }
        } message: {
            Text("Transactions this schedule already created are kept.")
        }
        .alert("Action Failed", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: - Calendar Grid

    private var calendarGridSection: some View {
        VStack(spacing: 8) {
            // Weekday symbols
            HStack(spacing: 0) {
                ForEach(BillsCalendarEngine.weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            let leadingOffset = BillsCalendarEngine.leadingEmptyDays(year: selectedYear, month: selectedMonth)
            let days = BillsCalendarEngine.daysInMonth(year: selectedYear, month: selectedMonth)
            let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(0..<leadingOffset, id: \.self) { _ in
                    Color.clear.frame(height: 44)
                }

                ForEach(days, id: \.yyyymmdd) { day in
                    let dayItems = itemsByDate[day] ?? []
                    CalendarDayCell(
                        day: day,
                        isToday: day == today,
                        isSelected: selectedDate == day,
                        items: dayItems,
                        onTap: {
                            if selectedDate == day {
                                selectedDate = nil
                            } else {
                                selectedDate = day
                            }
                        }
                    )
                }
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Summary Strip

    private var summaryStripSection: some View {
        HStack(spacing: 12) {
            summaryMetric(title: "Upcoming", amount: summary.upcomingTotal, color: .primary)
            Divider().frame(height: 24)
            summaryMetric(title: "Overdue", amount: summary.overdueTotal, color: .red)
            Divider().frame(height: 24)
            summaryMetric(title: "Paid", amount: summary.paidTotal, color: .green)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func summaryMetric(title: String, amount: Int, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(budgetStore.displayBalance(amount))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Filter Pills

    private var filterPillsSection: some View {
        HStack(spacing: 8) {
            ForEach(BillFilter.allCases) { filter in
                Button {
                    activeFilter = filter
                } label: {
                    Text(filter.rawValue)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            activeFilter == filter ? Color.accentColor : Color(uiColor: .tertiarySystemFill),
                            in: Capsule()
                        )
                        .foregroundStyle(activeFilter == filter ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }

            if selectedDate != nil {
                Spacer()
                Button {
                    selectedDate = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                        Text("Day \(selectedDate!.day)")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Cards List

    @ViewBuilder
    private var cardsListSection: some View {
        if filteredItems.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "calendar.badge.checkmark")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .padding(.top, 24)
                Text(tabMode == .recurring ? "No Schedules Due" : "No Card Bills Due")
                    .font(.headline)
                Text(selectedDate != nil ? "No items scheduled for this date." : "No transactions match the selected filter.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else {
            LazyVStack(spacing: 10) {
                ForEach(filteredItems) { item in
                    BillCardView(
                        item: item,
                        budgetStore: budgetStore,
                        onEdit: {
                            if let summary = item.scheduleSummary {
                                editingSchedule = summary
                            } else {
                                showingCreditCardsSetup = true
                            }
                        },
                        onPost: { todayOnly in
                            if let summary = item.scheduleSummary {
                                run { try await budgetStore.postScheduleTransaction(summary, today: todayOnly) }
                            }
                        },
                        onSkip: {
                            if let summary = item.scheduleSummary {
                                run { try await budgetStore.skipScheduleNextDate(summary) }
                            }
                        },
                        onDelete: {
                            if let summary = item.scheduleSummary {
                                pendingDelete = summary
                            }
                        }
                    )
                }
            }
        }
    }
}

// MARK: - Calendar Day Cell

private struct CalendarDayCell: View {
    let day: DayDate
    let isToday: Bool
    let isSelected: Bool
    let items: [BillCalendarItem]
    let onTap: () -> Void

    private var topItem: BillCalendarItem? {
        items.first
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                ZStack {
                    if isSelected {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 28, height: 28)
                    } else if isToday {
                        Circle()
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .frame(width: 28, height: 28)
                    }

                    Text("\(day.day)")
                        .font(.caption.weight(isSelected || isToday ? .bold : .regular))
                        .foregroundStyle(isSelected ? Color.white : (items.isEmpty ? Color.secondary : Color.primary))
                }

                // Item indicator badge
                if let item = topItem {
                    HStack(spacing: 2) {
                        Circle()
                            .fill(item.status.tint)
                            .frame(width: 5, height: 5)
                        if items.count > 1 {
                            Circle()
                                .fill(Color.secondary)
                                .frame(width: 4, height: 4)
                        }
                    }
                    .frame(height: 6)
                } else {
                    Spacer().frame(height: 6)
                }
            }
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Bill Card Row

private struct BillCardView: View {
    let item: BillCalendarItem
    let budgetStore: BudgetStore
    let onEdit: () -> Void
    let onPost: (_ todayOnly: Bool) -> Void
    let onSkip: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: 12) {
                // Leading Icon
                ZStack {
                    Circle()
                        .fill(Color(uiColor: .tertiarySystemFill))
                        .frame(width: 40, height: 40)
                    Image(systemName: item.isCreditCard ? "creditcard.fill" : "repeat")
                        .font(.subheadline)
                        .foregroundStyle(item.status.tint)
                }

                // Main Info
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text(budgetStore.displayBalance(item.amount))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(item.amount > 0 ? Color.green : Color.primary)

                        Text("•")
                            .foregroundStyle(.secondary)

                        Text(item.relativeDueText)
                            .font(.caption)
                            .foregroundStyle(item.status.tint)
                    }

                    if let sub = subtitleText {
                        Text(sub)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Trailing Calendar Date Badge (e.g. 07 SEP)
                VStack(spacing: 0) {
                    Text(item.dayString)
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.primary)
                    Text(item.monthAbbreviation)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.red)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let schedule = item.scheduleSummary, !schedule.completed {
                Button {
                    onPost(false)
                } label: {
                    Label("Post Transaction", systemImage: "plus.circle")
                }

                Button {
                    onPost(true)
                } label: {
                    Label("Post Transaction Today", systemImage: "calendar.badge.plus")
                }

                if schedule.isRecurring {
                    Button {
                        onSkip()
                    } label: {
                        Label("Skip Occurrence", systemImage: "forward.end")
                    }
                }

                Divider()

                Button {
                    onEdit()
                } label: {
                    Label("Edit Schedule", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete Schedule", systemImage: "trash")
                }
            } else if item.isCreditCard {
                Button {
                    onEdit()
                } label: {
                    Label("Configure Credit Cards", systemImage: "gearshape")
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let schedule = item.scheduleSummary {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }

                if !schedule.completed, schedule.isRecurring {
                    Button {
                        onSkip()
                    } label: {
                        Label("Skip", systemImage: "forward.end")
                    }
                    .tint(.orange)
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if let schedule = item.scheduleSummary, !schedule.completed {
                Button {
                    onPost(false)
                } label: {
                    Label("Post", systemImage: "plus.circle")
                }
                .tint(.green)
            }
        }
    }

    private var subtitleText: String? {
        let parts = [item.categoryName, item.accountName].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
}
