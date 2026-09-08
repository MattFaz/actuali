import SwiftUI

/// One automation's editor screen: type picker, the type's configuration
/// form, priority, note, and delete — port of the web's AutomationEditorPane
/// and the editor/* form components.
struct AutomationEntryEditor: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Binding var entry: AutomationEntry
    let error: AutomationError?
    let data: BudgetStore.AutomationEditorData
    let entries: [AutomationEntry]
    let onAddLimit: () -> Void
    let onDelete: () -> Void

    private var isContribution: Bool {
        !AutomationDisplayType.nonContribution.contains(entry.displayType)
    }

    /// Singleton types already used by another entry can't be picked.
    private var disabledTypes: Set<AutomationDisplayType> {
        var disabled: Set<AutomationDisplayType> = []
        for other in entries where other.id != entry.id {
            if AutomationDisplayType.singleton.contains(other.displayType) {
                disabled.insert(other.displayType)
            }
        }
        return disabled
    }

    var body: some View {
        Form {
            if let error {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(error.title).font(.footnote.weight(.semibold))
                            Text(error.detail).font(.caption)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.red)
                }
            }

            if isContribution {
                Section("Automation Type") {
                    typePicker
                }
            } else {
                Section {
                    Text(entry.displayType.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            configurationForm

            if entry.template.priority != nil {
                Section {
                    Stepper(value: priorityBinding, in: 0...99) {
                        LabeledContent("Priority", value: "\(entry.template.priority ?? 0)")
                    }
                } footer: {
                    Text("Lower priorities budget first; priorities above 0 stop once available funds run out.")
                }
            }

            Section("Note") {
                TextField(
                    "Note",
                    text: Binding(
                        get: { entry.template.description ?? "" },
                        set: { entry.template.description = $0.isEmpty ? nil : $0 }),
                    axis: .vertical)
                .lineLimit(2...5)
            }

            Section {
                Button("Delete Automation", role: .destructive, action: onDelete)
            }
        }
        .navigationTitle(entry.displayType.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Type picker

    private var typePicker: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
            ForEach(AutomationDisplayType.allCases.filter {
                !AutomationDisplayType.nonContribution.contains($0)
            }) { type in
                let isActive = type == entry.displayType
                let isDisabled = !isActive && disabledTypes.contains(type)
                Button {
                    entry = BudgetAutomations.convert(entry, to: type)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(type.label, systemImage: type.systemImage)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(type.explanation)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(3, reservesSpace: true)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isActive ? Color.accentColor.opacity(0.15) : Color(.secondarySystemGroupedBackground)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isActive ? Color.accentColor : Color(.separator)))
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.45 : 1)
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        .listRowBackground(Color.clear)
    }

    // MARK: - Per-type forms

    @ViewBuilder
    private var configurationForm: some View {
        switch entry.displayType {
        case .fixed: fixedForm
        case .schedule: scheduleForm
        case .by: byForm
        case .percentage: percentageForm
        case .historical: historicalForm
        case .limit: limitForm
        case .refill: refillForm
        case .remainder: remainderForm
        case .goal: goalForm
        }
    }

    private var fixedForm: some View {
        Section("Configuration") {
            AutomationAmountField(title: String(localized: "Amount"), amount: $entry.template.amount)
            Stepper(value: periodAmountBinding, in: 1...999) {
                LabeledContent("Every", value: "\(entry.template.period?.amount ?? 1)")
            }
            Picker("Period", selection: periodUnitBinding) {
                Text("Days").tag(GoalTemplate.PeriodUnit.day)
                Text("Weeks").tag(GoalTemplate.PeriodUnit.week)
                Text("Months").tag(GoalTemplate.PeriodUnit.month)
                Text("Years").tag(GoalTemplate.PeriodUnit.year)
            }
        }
    }

    @ViewBuilder
    private var scheduleForm: some View {
        let selectable = data.schedules
            .filter { !$0.completed && !($0.name ?? "").isEmpty }
            .sorted { ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending }
        if selectable.isEmpty {
            Section("Configuration") {
                Text("No schedules found. Create one in the Schedules tab first.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section("Configuration") {
                Picker("Schedule", selection: scheduleBinding(selectable)) {
                    Text("Select a schedule").tag("")
                    ForEach(selectable, id: \.id) { schedule in
                        Text(schedule.name ?? "").tag(schedule.id)
                    }
                }
                Picker("Savings mode", selection: Binding(
                    get: { entry.template.full == true },
                    set: { entry.template.full = $0 ? true : nil })) {
                    Text("Save up for the next occurrence").tag(false)
                    Text("Cover each occurrence when it occurs").tag(true)
                }
                AutomationAdjustmentFields(
                    adjustment: $entry.template.adjustment,
                    adjustmentType: $entry.template.adjustmentType)
            }
        }
    }

    private var byForm: some View {
        Section {
            AutomationAmountField(title: String(localized: "Total amount"), amount: $entry.template.amount)
            YearMonthPicker(title: String(localized: "Target month"), month: Binding(
                get: { entry.template.month ?? BudgetMonthMath.currentMonth() },
                set: { entry.template.month = $0 }))
            Toggle("Repeats", isOn: Binding(
                get: { entry.template.annual != nil },
                set: { repeats in
                    if repeats {
                        entry.template.annual = false
                        entry.template.repeatCount = entry.template.repeatCount ?? 1
                    } else {
                        entry.template.annual = nil
                        entry.template.repeatCount = nil
                    }
                }))
            if entry.template.annual != nil {
                Stepper(value: repeatBinding, in: 1...99) {
                    LabeledContent("Repeat every", value: "\(entry.template.repeatCount ?? 1)")
                }
                Picker("Period", selection: Binding(
                    get: { entry.template.annual == true },
                    set: { entry.template.annual = $0 })) {
                    Text("Months").tag(false)
                    Text("Years").tag(true)
                }
            }
            Toggle("Allow early spending", isOn: Binding(
                get: { entry.template.type == .spend },
                set: { entry.template = BudgetAutomations.setEarlySpending(entry.template, enabled: $0) }))
            if entry.template.type == .spend {
                YearMonthPicker(title: String(localized: "Start spending in"), month: Binding(
                    get: { entry.template.from ?? entry.template.month ?? BudgetMonthMath.currentMonth() },
                    set: { entry.template.from = $0 }))
            }
        } header: {
            Text("Configuration")
        } footer: {
            Text("Without early spending, purchases before the target month leave a gap the next contribution has to make up. Turn it on to tell Actual spending is expected from a chosen month onwards.")
        }
    }

    private var percentageForm: some View {
        Section("Configuration") {
            Picker("Category", selection: Binding(
                get: { entry.template.category ?? "" },
                set: { entry.template.category = $0.isEmpty ? nil : $0 })) {
                if (entry.template.category ?? "").isEmpty {
                    Text("Select a category").tag("")
                }
                Section("Special categories") {
                    Text("Total of all income").tag("all income")
                    if entry.template.previous != true {
                        Text("Available funds to budget").tag("available funds")
                    }
                }
                Section("Income categories") {
                    ForEach(data.incomeSources, id: \.id) { source in
                        Text(source.name).tag(source.id)
                    }
                }
            }
            LabeledContent("Percentage") {
                TextField("Percent", value: Binding(
                    get: { entry.template.percent ?? 0 },
                    set: { entry.template.percent = $0 }), format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 100)
                Text("%").foregroundStyle(.secondary)
            }
            Picker("Percentage of", selection: Binding(
                get: { entry.template.previous == true },
                set: { previous in
                    entry.template.previous = previous
                    // Available funds has no "last month" figure.
                    if previous, entry.template.category == "available funds" {
                        entry.template.category = nil
                    }
                })) {
                Text("This month").tag(false)
                Text("Last month").tag(true)
            }
        }
    }

    private var historicalForm: some View {
        Section("Configuration") {
            Picker("Mode", selection: Binding(
                get: { entry.template.type == .copy },
                set: { entry.template = BudgetAutomations.setHistoricalMode(entry.template, copyMode: $0) })) {
                Text("Copy a previous month").tag(true)
                Text("Average of previous months").tag(false)
            }
            Stepper(value: historicalMonthsBinding, in: 1...99) {
                LabeledContent("Number of months back", value: "\(historicalMonthsBinding.wrappedValue)")
            }
            if entry.template.type == .average {
                AutomationAdjustmentFields(
                    adjustment: $entry.template.adjustment,
                    adjustmentType: $entry.template.adjustmentType)
            }
        }
    }

    private var limitForm: some View {
        Section {
            AutomationAmountField(title: String(localized: "Amount"), amount: Binding(
                get: { limitBinding.wrappedValue.amount },
                set: { limitBinding.wrappedValue.amount = $0 ?? 0 }))
            Picker("Every", selection: Binding(
                get: { limitBinding.wrappedValue.period },
                set: { period in
                    limitBinding.wrappedValue.period = period
                    if period == .weekly, limitBinding.wrappedValue.start == nil {
                        limitBinding.wrappedValue.start = defaultWeeklyStart
                    }
                })) {
                Text("Day").tag(GoalTemplate.LimitPeriod.daily)
                Text("Week").tag(GoalTemplate.LimitPeriod.weekly)
                Text("Month").tag(GoalTemplate.LimitPeriod.monthly)
            }
            if limitBinding.wrappedValue.period == .weekly {
                Picker("Weekday", selection: weekdayBinding) {
                    ForEach(0..<7, id: \.self) { index in
                        Text(Calendar.current.weekdaySymbols[index]).tag(index)
                    }
                }
            }
            Toggle("Retain existing funds over the cap", isOn: Binding(
                get: { limitBinding.wrappedValue.hold },
                set: { limitBinding.wrappedValue.hold = $0 }))
        } header: {
            Text("Configuration")
        } footer: {
            Text("A weekly or daily cap is multiplied by the number of weeks or days in the month, so the effective monthly cap changes with each month.")
        }
    }

    @ViewBuilder
    private var refillForm: some View {
        Section {
            Text("Each month, this tops the category back up to the balance cap.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !entries.contains(where: { $0.displayType == .limit }) {
                Button("Add Balance Cap", action: onAddLimit)
            }
        }
    }

    private var remainderForm: some View {
        Section {
            Stepper(value: weightBinding, in: 1...99) {
                LabeledContent("Weight", value: AutomationSentences.trimTrailingZeros(entry.template.weight ?? 1))
            }
        } header: {
            Text("Configuration")
        } footer: {
            Text("Categories splitting the remainder receive it proportionally to their weights.")
        }
    }

    private var goalForm: some View {
        Section("Configuration") {
            AutomationAmountField(title: String(localized: "Target amount"), amount: $entry.template.amount)
        }
    }

    // MARK: - Bindings

    private var priorityBinding: Binding<Int> {
        Binding(
            get: { entry.template.priority ?? 0 },
            set: { entry.template.priority = max(0, $0) })
    }

    private var periodAmountBinding: Binding<Int> {
        Binding(
            get: { entry.template.period?.amount ?? 1 },
            set: {
                entry.template.period = .init(
                    period: entry.template.period?.period ?? .month, amount: max(1, $0))
            })
    }

    private var periodUnitBinding: Binding<GoalTemplate.PeriodUnit> {
        Binding(
            get: { entry.template.period?.period ?? .month },
            set: {
                entry.template.period = .init(
                    period: $0, amount: entry.template.period?.amount ?? 1)
            })
    }

    private var repeatBinding: Binding<Int> {
        Binding(
            get: { entry.template.repeatCount ?? 1 },
            set: { entry.template.repeatCount = max(1, $0) })
    }

    private var historicalMonthsBinding: Binding<Int> {
        Binding(
            get: {
                entry.template.type == .copy
                    ? entry.template.lookBack ?? 1 : entry.template.numMonths ?? 1
            },
            set: {
                if entry.template.type == .copy {
                    entry.template.lookBack = max(1, $0)
                } else {
                    entry.template.numMonths = max(1, $0)
                }
            })
    }

    private var weightBinding: Binding<Int> {
        Binding(
            get: { Int(entry.template.weight ?? 1) },
            set: { entry.template.weight = Double(max(1, $0)) })
    }

    private var limitBinding: Binding<GoalTemplate.Limit> {
        Binding(
            get: {
                entry.template.limit
                    ?? .init(amount: 500, hold: false, period: .monthly, start: nil)
            },
            set: { limit in
                entry.template.limit = limit
                // limit-type templates mirror the amount at the top level.
                entry.template.amount = limit.amount
            })
    }

    /// Earliest fixed-automation start or save-by target, else the first of
    /// the current month — the web's getDefaultWeeklyStart.
    private var defaultWeeklyStart: String {
        var starts: [String] = []
        for other in entries {
            if other.template.type == .periodic, let starting = other.template.starting {
                starts.append(starting)
            } else if other.template.type == .by || other.template.type == .spend,
                      let month = other.template.month {
                starts.append("\(month)-01")
            }
        }
        return starts.min() ?? BudgetMonthMath.firstDayOfMonth(BudgetMonthMath.currentMonth())
    }

    /// Weekday of the weekly limit's start date (0 = Sunday), moved within
    /// its week on change — the web's setDay behavior.
    private var weekdayBinding: Binding<Int> {
        Binding(
            get: {
                let start = limitBinding.wrappedValue.start ?? defaultWeeklyStart
                guard let day = DayDate(iso: start) else { return 0 }
                return day.weekday - 1
            },
            set: { index in
                let start = limitBinding.wrappedValue.start ?? defaultWeeklyStart
                guard let day = DayDate(iso: start) else { return }
                limitBinding.wrappedValue.start = day.adding(days: (index + 1) - day.weekday).iso
            })
    }

    private func scheduleBinding(_ selectable: [GoalScheduleInfo]) -> Binding<String> {
        Binding(
            get: {
                entry.template.scheduleId
                    ?? selectable.first { $0.name == entry.template.name }?.id
                    ?? ""
            },
            set: { id in
                guard let schedule = selectable.first(where: { $0.id == id }) else { return }
                entry.template.scheduleId = schedule.id
                entry.template.name = schedule.name ?? ""
            })
    }
}

// MARK: - Shared field components

/// Currency amount field editing the template's whole-unit Double.
struct AutomationAmountField: View {
    let title: String
    @Binding var amount: Double?

    var body: some View {
        LabeledContent(title) {
            TextField(title, value: Binding(
                get: { amount ?? 0 },
                set: { amount = $0 }), format: .number.precision(.fractionLength(0...2)))
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 120)
        }
    }
}

/// Increase/decrease adjustment on schedule and average automations.
struct AutomationAdjustmentFields: View {
    @Binding var adjustment: Double?
    @Binding var adjustmentType: GoalTemplate.AdjustmentType?

    private enum Direction: String, CaseIterable {
        case none, increase, decrease
    }

    private var direction: Direction {
        guard let adjustment, adjustment != 0 else { return adjustment == nil ? .none : .increase }
        return adjustment < 0 ? .decrease : .increase
    }

    var body: some View {
        Picker("Adjustment", selection: Binding(
            get: { direction },
            set: { direction in
                switch direction {
                case .none:
                    adjustment = nil
                    adjustmentType = nil
                case .increase:
                    adjustment = abs(adjustment ?? 5)
                    adjustmentType = adjustmentType ?? .percent
                case .decrease:
                    adjustment = -abs(adjustment ?? 5)
                    adjustmentType = adjustmentType ?? .percent
                }
            })) {
            Text("None").tag(Direction.none)
            Text("Increase").tag(Direction.increase)
            Text("Decrease").tag(Direction.decrease)
        }
        if adjustment != nil {
            LabeledContent("Adjust by") {
                TextField("Amount", value: Binding(
                    get: { abs(adjustment ?? 0) },
                    set: { value in
                        let sign: Double = direction == .decrease ? -1 : 1
                        adjustment = sign * abs(value)
                    }), format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 80)
            }
            Picker("Unit", selection: Binding(
                get: { adjustmentType ?? .percent },
                set: { adjustmentType = $0 })) {
                Text("Percent").tag(GoalTemplate.AdjustmentType.percent)
                Text("Fixed amount").tag(GoalTemplate.AdjustmentType.fixed)
            }
        }
    }
}

/// A "YYYY-MM" month picker as paired month/year menus.
struct YearMonthPicker: View {
    let title: String
    @Binding var month: String

    private var components: (year: Int, month: Int) {
        BudgetMonthMath.yearAndMonth(month) ?? (2026, 1)
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Picker("Month", selection: Binding(
                get: { components.month },
                set: { month = String(format: "%04d-%02d", components.year, $0) })) {
                ForEach(1...12, id: \.self) { index in
                    Text(Calendar.current.shortMonthSymbols[index - 1]).tag(index)
                }
            }
            .labelsHidden()
            Picker("Year", selection: Binding(
                get: { components.year },
                set: { month = String(format: "%04d-%02d", $0, components.month) })) {
                ForEach(yearRange, id: \.self) { year in
                    Text(String(year)).tag(year)
                }
            }
            .labelsHidden()
        }
    }

    private var yearRange: [Int] {
        let current = BudgetMonthMath.yearAndMonth(BudgetMonthMath.currentMonth())?.year ?? 2026
        let selected = components.year
        return Array(min(current - 10, selected)...max(current + 15, selected))
    }
}

// MARK: - Cleanup editor

/// End-of-month cleanup configuration — port of the web's CleanupAutomation:
/// the category can give up leftovers (source) and/or receive them (sink),
/// globally and per pool.
struct CleanupEditor: View {
    @Binding var cleanup: CleanupConfig
    var groups: [(id: String, name: String)]
    let onCreateGroup: (String) async throws -> String
    let onDelete: () -> Void

    @State private var addingPoolName = ""
    @State private var showingNewPool = false
    @State private var poolError: String?

    private func groupName(_ id: String) -> String {
        groups.first { $0.id == id }?.name ?? "Unknown pool"
    }

    var body: some View {
        Form {
            Section {
                Text("At the end of the month, sources give up their leftover balance and sinks receive it, split by weight. Pools scope the exchange to their members.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Globally") {
                Toggle("Give up leftover funds", isOn: $cleanup.global.send)
                Toggle("Receive shared funds", isOn: $cleanup.global.take)
                if cleanup.global.take {
                    Stepper(value: Binding(
                        get: { Int(cleanup.global.weight) },
                        set: { cleanup.global.weight = Double(max(1, $0)) }), in: 1...99) {
                        LabeledContent(
                            "Weight",
                            value: AutomationSentences.trimTrailingZeros(cleanup.global.weight))
                    }
                }
            }

            ForEach($cleanup.groups) { $group in
                Section(groupName(group.groupId)) {
                    Toggle("Give up leftover funds", isOn: $group.send)
                    Toggle("Receive shared funds", isOn: $group.take)
                    if group.take {
                        Toggle("Only enough to cover any overspending", isOn: $group.overspendOnly)
                        if !group.overspendOnly {
                            Stepper(value: Binding(
                                get: { Int(group.weight) },
                                set: { group.weight = Double(max(1, $0)) }), in: 1...99) {
                                LabeledContent(
                                    "Weight",
                                    value: AutomationSentences.trimTrailingZeros(group.weight))
                            }
                        }
                    }
                    Button("Remove Pool", role: .destructive) {
                        cleanup.groups.removeAll { $0.groupId == group.groupId }
                    }
                }
            }

            Section {
                let unusedGroups = groups.filter { group in
                    !cleanup.groups.contains { $0.groupId == group.id }
                }
                Menu {
                    ForEach(unusedGroups, id: \.id) { group in
                        Button(group.name) {
                            cleanup.groups.append(.init(groupId: group.id))
                        }
                    }
                    Button("New Pool…") { showingNewPool = true }
                } label: {
                    Label("Add to a Pool", systemImage: "plus")
                }
                if let poolError {
                    Text(poolError).font(.footnote).foregroundStyle(.red)
                }
            }

            Section {
                Button("Remove End of Month Cleanup", role: .destructive, action: onDelete)
            }
        }
        .navigationTitle("End of Month Cleanup")
        .navigationBarTitleDisplayMode(.inline)
        .alert("New Pool", isPresented: $showingNewPool) {
            TextField("Pool name", text: $addingPoolName)
            Button("Cancel", role: .cancel) { addingPoolName = "" }
            Button("Create") {
                let name = addingPoolName.trimmingCharacters(in: .whitespaces)
                addingPoolName = ""
                guard !name.isEmpty else { return }
                Task {
                    do {
                        let id = try await onCreateGroup(name)
                        if !cleanup.groups.contains(where: { $0.groupId == id }) {
                            cleanup.groups.append(.init(groupId: id))
                        }
                    } catch {
                        poolError = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("Pools scope the cleanup exchange to their member categories.")
        }
    }
}
