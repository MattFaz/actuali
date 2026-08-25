import SwiftUI

struct RulesSettingsView: View {
    var body: some View {
        RulesListView()
            .navigationTitle("Rules")
    }
}

#Preview {
    NavigationStack {
        RulesSettingsView()
            .environmentObject(BudgetStore.previewInstance())
    }
}
