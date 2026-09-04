import SwiftUI

/// The scheduled-transactions screen (GH #221). Read-only in M2; the toolbar
/// add button, row navigation and swipe actions arrive with M4 and M5.
///
/// Completed schedules are hidden behind a toggle, matching the web — a
/// finished schedule is history, not something to scroll past every time.
struct SchedulesListView: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    @State private var searchText = ""
    @State private var showCompleted = false
    @State private var isAddingSchedule = false
    
    @State private var pendingDelete: ScheduleSummary?
    @State private var actionError: String?

    /// Row actions all write to the server; surface failures rather than
    /// letting a tap look like it worked.
    private func run(_ operation: @escaping () async throws -> Void) {
        Task {
            do { try await operation() }
            catch { actionError = error.localizedDescription }
        }
    }

    var body: some View {
        Group {
            if visibleSchedules.isEmpty {
                emptyState
            } else {
                List {
                    Section {
                        ForEach(visibleSchedules) { schedule in
                            NavigationLink {
                                ScheduleEditView(editing: schedule, budgetStore: budgetStore)
                            } label: {
                                ScheduleRow(
                                    schedule: schedule,
                                    status: budgetStore.scheduleStatuses[schedule.id] ?? .scheduled,
                                    accountName: accountName(schedule),
                                    payeeName: payeeName(schedule))
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    pendingDelete = schedule
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }

                                // Only a recurrence has a next occurrence to
                                // skip to; skipScheduleNextDate throws on
                                // anything else.
                                if !schedule.completed, schedule.isRecurring {
                                    Button {
                                        run { try await budgetStore.skipScheduleNextDate(schedule) }
                                    } label: {
                                        Label("Skip", systemImage: "forward.end")
                                    }
                                    .tint(.orange)
                                }
                            }
                            .contextMenu {
                                if !schedule.completed {
                                    Button {
                                        run { try await budgetStore.postScheduleTransaction(schedule, today: false) }
                                    } label: {
                                        Label("Post Transaction", systemImage: "plus.circle")
                                    }
                                    Button {
                                        run { try await budgetStore.postScheduleTransaction(schedule, today: true) }
                                    } label: {
                                        Label("Post Transaction Today", systemImage: "calendar.badge.plus")
                                    }
                                    if schedule.isRecurring {
                                        Button {
                                            run { try await budgetStore.skipScheduleNextDate(schedule) }
                                        } label: {
                                            Label("Skip Next Date", systemImage: "forward.end")
                                        }
                                    }
                                }

                                Divider()

                                Button {
                                    run { try await budgetStore.setScheduleCompleted(
                                        schedule, completed: !schedule.completed) }
                                } label: {
                                    schedule.completed
                                        ? Label("Restart", systemImage: "arrow.clockwise")
                                        : Label("Mark Completed", systemImage: "checkmark.seal")
                                }

                                Button(role: .destructive) {
                                    pendingDelete = schedule
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } footer: {
                        if completedCount > 0 && !showCompleted {
                            Text("\(completedCount) completed schedule\(completedCount == 1 ? "" : "s") hidden.")
                        }
                    }
                }
            }
        }
        .navigationTitle("Scheduled Transactions")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search schedules")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    BillsCalendarView()
                } label: {
                    Label("Calendar", systemImage: "calendar")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Show Completed", isOn: $showCompleted)

                    NavigationLink {
                        DiscoverSchedulesView()
                    } label: {
                        Label("Find Schedules", systemImage: "sparkle.magnifyingglass")
                    }
                } label: {
                    Label("Options", systemImage: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isAddingSchedule = true
                } label: {
                    Label("Add Schedule", systemImage: "plus")
                }
                .disabled(budgetStore.accounts.allSatisfy(\.closed))
            }
        }
        .refreshable { await budgetStore.loadSchedules() }
        .task { await budgetStore.loadSchedules() }
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
            Button("OK") {}
        } message: {
            Text(actionError ?? "")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            ContentUnavailableView {
                Label("No Scheduled Transactions", systemImage: "calendar.badge.clock")
            } description: {
                Text("Create a schedule to track a recurring bill or paycheck.")
            } actions: {
                Button("New Schedule") { isAddingSchedule = true }
            }
        }
    }

    // MARK: - Filtering

    private var completedCount: Int {
        budgetStore.schedules.filter(\.completed).count
    }

    private var visibleSchedules: [ScheduleSummary] {
        budgetStore.schedules
            .filter { showCompleted || !$0.completed }
            .filter { matchesSearch($0) }
    }

    /// Search covers everything visible on the row, so typing an account or
    /// payee name finds the schedule even when it was never given a name.
    private func matchesSearch(_ schedule: ScheduleSummary) -> Bool {
        guard !searchText.isEmpty else { return true }
        let haystack = [
            schedule.name,
            payeeName(schedule),
            accountName(schedule),
            ScheduleDescription.dateSummary(schedule.dateCondition),
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(searchText)
    }

    private func accountName(_ schedule: ScheduleSummary) -> String? {
        schedule.accountId.flatMap { id in
            budgetStore.accounts.first { $0.id == id }?.name
        }
    }

    private func payeeName(_ schedule: ScheduleSummary) -> String? {
        schedule.payeeId.flatMap { id in
            budgetStore.payees.first { $0.id == id }?.name
        }
    }
}

/// One schedule in the list.
struct ScheduleRow: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    let schedule: ScheduleSummary
    let status: ScheduleStatus
    let accountName: String?
    let payeeName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                ScheduleStatusBadge(status: status)
                Spacer()
                Text(amountText)
                    .font(.body)
                    .monospacedDigit()
                    .foregroundStyle(schedule.postAmount > 0 ? Color.green : Color.primary)
            }
            HStack {
                if let accountName, !accountName.isEmpty {
                    Text(accountName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if schedule.isRecurring {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Recurring")
                }
                Text(nextDateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("scheduleRow.\(schedule.id)")
    }

    /// A schedule need not have a name; fall back to the payee, then the
    /// account, so the row is never blank.
    private var title: String {
        if let name = schedule.name, !name.isEmpty { return name }
        if let payeeName, !payeeName.isEmpty { return payeeName }
        return accountName ?? "Schedule"
    }

    private var nextDateText: String {
        guard let nextDate = schedule.nextDate else { return "No next date" }
        return ScheduleDescription.mediumDate(nextDate)
    }

    /// `~` for an approximate amount and a range for `isbetween`, matching the
    /// web's amount cell.
    private var amountText: String {
        switch (schedule.amountOp, schedule.amount) {
        case (.isBetween, .range(let low, let high)):
            let ordered = low <= high ? (low, high) : (high, low)
            return "\(budgetStore.displayBalance(ordered.0)) – \(budgetStore.displayBalance(ordered.1))"
        default:
            return Self.formattedAmount(
                budgetStore.displayBalance(schedule.postAmount), amountOp: schedule.amountOp)
        }
    }

    nonisolated static func formattedAmount(_ amount: String, amountOp: ScheduleAmountOp) -> String {
        amountOp == .isApprox ? "~ " + amount : amount
    }
}

#if DEBUG
struct ScheduleRowUITestFixture: View {
    private let schedule = ScheduleSummary(
        id: "fixture", name: "Rent", ruleId: nil,
        nextDate: DayDate(year: 2026, month: 10, day: 1), nextDateRowId: nil,
        baseNextDateTs: nil, accountId: nil, payeeId: nil,
        amount: .fixed(-120_000), amountOp: .isApprox, dateOp: nil,
        dateCondition: .recurring(RecurConfig(json: [
            "frequency": "monthly", "start": "2026-09-03",
        ])!), postsTransaction: false, completed: false,
        customUpcomingLength: nil, sortOrder: nil, isCustom: false,
        conditionsJSON: nil, actionsJSON: nil, categoryId: nil)

    var body: some View {
        ScheduleRow(
            schedule: schedule, status: .upcoming,
            accountName: "Checking", payeeName: "Landlord")
            .padding()
    }
}
#endif

#Preview {
    NavigationStack {
        SchedulesListView()
            .environmentObject(BudgetStore.previewInstance())
    }
}
