import SwiftUI

struct BudgetViewSettingsView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale: Locale
    @State private var isCategoryStatusColorPickerExpanded = false
    @State private var showingCategoryStatusColorInfo = false

    var body: some View {
        Form {
            // Settings keeps the presentation options that are not available as
            // contextual shortcuts from the Budget tab.
            Section {
                Toggle(String(localized: "Category Status Dots"), isOn: $budgetStore.showCategoryStatusDots)
                Toggle(String(localized: "Budget Progress Bars"), isOn: $budgetStore.showBudgetProgressBars)
                Toggle(String(localized: "Inverse Progress Bars"), isOn: $budgetStore.showInverseBudgetProgressBars)
                    .disabled(!budgetStore.showBudgetProgressBars)
                Toggle(String(localized: "Overspent Badge"), isOn: $budgetStore.showOverspentBadge)
                Toggle(String(localized: "Show Balance Impact"), isOn: $budgetStore.showTransactionImpactCue)
                    .accessibilityIdentifier("budgetViewSettings.showBalanceImpact")
                Toggle(String(localized: "Hide Income Group"), isOn: $budgetStore.hideIncomeGroup)
                    .accessibilityIdentifier("budgetViewSettings.hideIncomeGroup")

                DisclosureGroup(
                    isExpanded: $isCategoryStatusColorPickerExpanded
                ) {
                    ForEach(CategoryProgressState.allCases, id: \.self) { state in
                        HStack {
                            ColorPicker(
                                state.statusText(locale: locale, bundle: .main),
                                selection: Binding(
                                    get: { budgetStore.categoryStatusDotColor(for: state) },
                                    set: { budgetStore.setCategoryStatusDotColor($0, for: state) }
                                ),
                                supportsOpacity: false
                            )
                            .accessibilityIdentifier("categoryStatusColorPicker.\(state.rawValue)")

                            Spacer()

                            Button {
                                budgetStore.resetCategoryStatusDotColor(for: state)
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .accessibilityHidden(true)
                            }
                            .buttonStyle(.borderless)
                            .disabled(!budgetStore.hasCustomCategoryStatusDotColor(for: state))
                            .accessibilityLabel(String(localized: "Reset to Default"))
                            .accessibilityIdentifier("categoryStatusColorReset.\(state.rawValue)")
                        }
                    }

                    // Inside the group, not in the label: a Button in a
                    // DisclosureGroup label merges with the row, so tapping
                    // the row opens the alert instead of expanding it. Last,
                    // so the scroll that reveals the pickers keeps it on
                    // screen.
                    Button {
                        showingCategoryStatusColorInfo = true
                    } label: {
                        Label("Color picker information", systemImage: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("categoryStatusColorPickerInfo")
                } label: {
                    Text(String(localized: "Color picker"))
                }
            } header: {
                Text(String(localized: "Presentation"))
            }

            // Mirrors the web's Settings → Experimental features toggle: the
            // flag is a synced preference, so flipping it here flips it for
            // every client on this budget.
            Section {
                Toggle(String(localized: "Budget Goal Templates"), isOn: Binding(
                    get: { budgetStore.goalTemplatesEnabled },
                    set: { enabled in
                        Task { await budgetStore.setGoalTemplatesEnabled(enabled) }
                    }
                ))
                .accessibilityIdentifier("budgetViewSettings.goalTemplates")
                .disabled(budgetStore.currentBudgetId == nil)
                Toggle(String(localized: "Automations Editor"), isOn: Binding(
                    get: { budgetStore.goalTemplatesUIEnabled },
                    set: { enabled in
                        Task { await budgetStore.setGoalTemplatesUIEnabled(enabled) }
                    }
                ))
                .disabled(budgetStore.currentBudgetId == nil || !budgetStore.goalTemplatesEnabled)
            } header: {
                Text(String(localized: "Experimental"))
            } footer: {
                Text(String(localized: "Set budgeting goals per category with #template and #goal lines in category notes, or with the visual automations editor, then apply them from the Budget tab's options menu. Synced with the web app's Goal Templates experimental features."))
            }
        }
        .readableWidth()
        .navigationTitle(String(localized: "Budget View"))
        .navigationBarTitleDisplayMode(.inline)
        .contentMargins(.horizontal, 6, for: .scrollContent)
        .alert(
            String(localized: "Color picker"),
            isPresented: $showingCategoryStatusColorInfo
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(String(localized: "Picked color will be used for both category status dots and progress bars."))
        }
    }
}
