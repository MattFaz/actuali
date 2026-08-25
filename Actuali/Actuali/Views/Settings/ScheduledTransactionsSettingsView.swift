import SwiftUI

struct ScheduledTransactionsSettingsView: View {
    var body: some View {
        SchedulesListView()
            .navigationTitle("Scheduled Transactions")
    }
}

#Preview {
    NavigationStack {
        ScheduledTransactionsSettingsView()
            .environmentObject(BudgetStore.previewInstance())
    }
}
