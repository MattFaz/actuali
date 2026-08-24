import SwiftUI

/// Offers recurring transactions as schedules ("Find schedules" on the web).
struct DiscoverSchedulesView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss

    @State private var proposals: [ScheduleDiscovery.Proposal] = []
    @State private var selected = Set<UUID>()
    @State private var isSearching = true
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isSearching {
                ProgressView("Looking for repeating transactions…")
            } else if proposals.isEmpty {
                ContentUnavailableView(
                    "Nothing Found",
                    systemImage: "magnifyingglass",
                    description: Text("No repeating transactions were found in your history."))
            } else {
                List(proposals, selection: $selected) { proposal in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(payeeName(proposal.payeeId))
                                .font(.body.weight(.medium))
                            Spacer()
                            Text(budgetStore.displayBalance(proposal.amount))
                                .monospacedDigit()
                        }
                        Text(ScheduleDescription.recurring(proposal.config))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(accountName(proposal.accountId))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .environment(\.editMode, .constant(.active))
            }
        }
        .navigationTitle("Find Schedules")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") { Task { await createSelected() } }
                    .disabled(selected.isEmpty || isCreating)
            }
        }
        .task { await search() }
        .alert("Couldn't Create Schedules", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func payeeName(_ id: String) -> String {
        budgetStore.payees.first { $0.id == id }?.name ?? "Unknown payee"
    }

    private func accountName(_ id: String) -> String {
        budgetStore.accounts.first { $0.id == id }?.name ?? "Unknown account"
    }

    private func search() async {
        isSearching = true
        defer { isSearching = false }
        proposals = await budgetStore.discoverSchedules()
    }

    private func createSelected() async {
        isCreating = true
        defer { isCreating = false }
        do {
            try await budgetStore.createSchedules(
                proposals.filter { selected.contains($0.id) }.map(\.formFields))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
