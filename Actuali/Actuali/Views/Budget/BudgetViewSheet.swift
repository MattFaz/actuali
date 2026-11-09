import SwiftUI

struct BudgetViewSheet: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var showingCategoryStatusColorInfo = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: budgetStore.budgetDisplayStyle == .clean
                        ? $budgetStore.showCleanBudgetOverview
                        : $budgetStore.showCompactBudgetOverview) {
                            Label("Show Overview", systemImage: "rectangle.topthird.inset.filled")
                        }
                        .accessibilityIdentifier("budgetView.showOverview")
                    Toggle(isOn: $budgetStore.showBudgetedAmounts) {
                        Label("Show Budgeted", systemImage: "banknote")
                    }
                    .accessibilityIdentifier("budgetView.showBudgetedAmounts")
                    Toggle(isOn: $budgetStore.showCompactSpentColumn) {
                        Label("Show Spent", systemImage: "tablecells.badge.ellipsis")
                    }
                    .accessibilityLabel("Show Spent Column")
                    .accessibilityIdentifier("budgetView.showCompactSpentColumn")
                    .disabled(budgetStore.budgetDisplayStyle != .compact)
                    Toggle(isOn: $budgetStore.showGroupTotals) {
                        Label("Group Totals", systemImage: "sum")
                    }
                    .accessibilityIdentifier("budgetView.showGroupTotals")
                    .disabled(budgetStore.budgetDisplayStyle == .clean)
                    Toggle(isOn: $budgetStore.showBudgetCheckInStrip) {
                        Label("Status Filters", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityIdentifier("budgetView.showBudgetCheckInStrip")
                    Toggle(isOn: $budgetStore.hideZeroBudgetCategories) {
                        Label("Hide Spent", systemImage: "line.3.horizontal.decrease")
                    }
                    .accessibilityLabel("Hide Spent Categories")
                    .accessibilityIdentifier("budgetView.hideZeroBudgetCategories")
                } header: {
                    Text("Presentation")
                }

                Section {
                    Toggle(isOn: $budgetStore.showCategoryStatusDots) {
                        Label("Category Status Dots", systemImage: "circle.fill")
                    }
                    .accessibilityIdentifier("budgetView.showCategoryStatusDots")
                    Toggle(isOn: $budgetStore.showBudgetProgressBars) {
                        Label("Budget Progress Bars", systemImage: "chart.bar.fill")
                    }
                    .accessibilityIdentifier("budgetView.showBudgetProgressBars")
                    Toggle(isOn: $budgetStore.showInverseBudgetProgressBars) {
                        Label("Inverse Progress Bars", systemImage: "arrow.left.arrow.right")
                    }
                    .accessibilityIdentifier("budgetView.showInverseBudgetProgressBars")
                    .disabled(!budgetStore.showBudgetProgressBars)
                    Toggle(isOn: $budgetStore.showOverspentBadge) {
                        Label("Overspent Badge", systemImage: "exclamationmark.circle")
                    }
                    .accessibilityIdentifier("budgetView.showOverspentBadge")
                    Toggle(isOn: $budgetStore.hideIncomeGroup) {
                        Label("Hide Income Group", systemImage: "eye.slash")
                    }
                    .accessibilityIdentifier("budgetView.hideIncomeGroup")
                } header: {
                    Text("Category Display")
                }

                Section {
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

                    Button {
                        showingCategoryStatusColorInfo = true
                    } label: {
                        Label("Color picker information", systemImage: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("categoryStatusColorPickerInfo")
                } header: {
                    Text("Category Status Colors")
                }
            }
            .readableWidth()
            .navigationTitle(String(localized: "Budget View"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("budgetView.done")
                }
            }
        }
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
