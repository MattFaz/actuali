import SwiftUI

/// Picks the schedule to link a batch of selected transactions to. Completed
/// schedules are left out, as in upstream's `ScheduleLink` modal.
struct ScheduleLinkPickerSheet: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    let onPick: (ScheduleSummary) -> Void

    @State private var searchText = ""

    private var visibleSchedules: [ScheduleSummary] {
        budgetStore.schedules.filter { schedule in
            guard !schedule.completed else { return false }
            guard !searchText.isEmpty else { return true }
            return [schedule.name, payeeName(schedule), accountName(schedule)]
                .compactMap(\.self)
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if visibleSchedules.isEmpty {
                    if searchText.isEmpty {
                        ContentUnavailableView(
                            ReportStrings.text("No Scheduled Transactions", locale: locale),
                            systemImage: "calendar.badge.clock"
                        )
                    } else {
                        ContentUnavailableView.search(text: searchText)
                    }
                } else {
                    List(visibleSchedules) { schedule in
                        Button {
                            onPick(schedule)
                            dismiss()
                        } label: {
                            ScheduleRow(
                                schedule: schedule,
                                status: budgetStore.scheduleStatuses[schedule.id] ?? .scheduled,
                                accountName: accountName(schedule),
                                payeeName: payeeName(schedule)
                            )
                            .foregroundStyle(.primary)
                        }
                        .accessibilityIdentifier("scheduleLinkPicker.\(schedule.id)")
                    }
                }
            }
            .searchable(text: $searchText, prompt: ReportStrings.text("Search schedules", locale: locale))
            .navigationTitle(ReportStrings.text("Link Schedule", locale: locale))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ReportStrings.text("Cancel", locale: locale)) { dismiss() }
                }
            }
            .task { await budgetStore.loadSchedules() }
        }
        .presentationDetents([.medium, .large])
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
