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

    var body: some View {
        Group {
            if visibleSchedules.isEmpty {
                emptyState
            } else {
                List {
                    Section {
                        ForEach(visibleSchedules) { schedule in
                            ScheduleRow(
                                schedule: schedule,
                                status: budgetStore.scheduleStatuses[schedule.id] ?? .scheduled,
                                accountName: accountName(schedule),
                                payeeName: payeeName(schedule))
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
                Menu {
                    Toggle("Show Completed", isOn: $showCompleted)
                } label: {
                    Label("Options", systemImage: "ellipsis.circle")
                }
            }
        }
        .refreshable { await budgetStore.loadSchedules() }
        .task { await budgetStore.loadSchedules() }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            ContentUnavailableView(
                "No Scheduled Transactions",
                systemImage: "calendar.badge.clock",
                description: Text("Schedules you create in Actual appear here."))
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
            HStack {
                Text(title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(amountText)
                    .font(.body)
                    .monospacedDigit()
                    .foregroundStyle(schedule.postAmount > 0 ? Color.green : Color.primary)
            }

            HStack(spacing: 6) {
                ScheduleStatusBadge(status: status)
                if schedule.isRecurring {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Recurring")
                }
                Spacer()
                Text(nextDateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    /// A schedule need not have a name; fall back to the payee, then the
    /// account, so the row is never blank.
    private var title: String {
        if let name = schedule.name, !name.isEmpty { return name }
        if let payeeName, !payeeName.isEmpty { return payeeName }
        return accountName ?? "Schedule"
    }

    private var subtitle: String? {
        var parts: [String] = []
        // Only repeat the payee when it isn't already doing duty as the title.
        if let payeeName, !payeeName.isEmpty, title != payeeName { parts.append(payeeName) }
        if let accountName, !accountName.isEmpty { parts.append(accountName) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
            return "\(budgetStore.formatCurrency(ordered.0)) – \(budgetStore.formatCurrency(ordered.1))"
        case (.isApprox, _):
            return "~" + budgetStore.formatCurrency(schedule.postAmount)
        default:
            return budgetStore.formatCurrency(schedule.postAmount)
        }
    }
}

#Preview {
    NavigationStack {
        SchedulesListView()
            .environmentObject(BudgetStore.previewInstance())
    }
}
