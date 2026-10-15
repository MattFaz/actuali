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

            // A device without a passcode has nothing to lock with; keep the
            // row while on so a lock set up before the passcode was removed
            // can still be turned off.
            if DeviceOwnerAuth.isAvailable || budgetStore.requireAppUnlock {
                Section {
                    Toggle(String(localized: "Require App Unlock"), isOn: Binding(
                        get: { budgetStore.requireAppUnlock },
                        set: { isOn in
                            if isOn {
                                Task { await budgetStore.enableAppLock() }
                            } else {
                                budgetStore.requireAppUnlock = false
                            }
                        }
                    ))
                    .accessibilityIdentifier("privacy.requireAppUnlock")
                } header: {
                    Text(String(localized: "App Lock"))
                } footer: {
                    Text(String(localized: "Unlock Actuali with Face ID, Touch ID, Optic ID, or your device passcode each time you open it or return to it."))
                }
            }
        }
        .readableWidth()
        .navigationTitle(String(localized: "Privacy"))
        .navigationBarTitleDisplayMode(.inline)
        .contentMargins(.horizontal, 6, for: .scrollContent)
    }
}
