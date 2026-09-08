import SwiftUI

struct PrivacySettingsView: View {
    @EnvironmentObject private var budgetStore: BudgetStore

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Hide Balances"), isOn: $budgetStore.hideBalances)
                Toggle(String(localized: "Shake to Toggle Balances"), isOn: $budgetStore.shakeToHideBalances)
                Toggle(String(localized: "Hide Decimal Places"), isOn: $budgetStore.hideDecimalPlaces)
            } header: {
                Text(String(localized: "Balance Visibility"))
            } footer: {
                Text(String(localized: "Hide Balances masks amounts across the app while leaving amount entry and reconciliation visible. Shake to Toggle lets you quickly mask or unmask amounts by shaking your phone. Hide Decimal Places rounds displayed amounts to whole units without changing their values."))
            }
        }
        .readableWidth()
        .navigationTitle(String(localized: "Privacy"))
        .navigationBarTitleDisplayMode(.inline)
        .contentMargins(.horizontal, 6, for: .scrollContent)
    }
}
