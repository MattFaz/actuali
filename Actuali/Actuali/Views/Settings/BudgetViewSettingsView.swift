import SwiftUI
import UIKit

private struct CategoryStatusColorPicker: UIViewRepresentable {
    @Binding var color: Color
    let accessibilityLabel: String
    let accessibilityIdentifier: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIColorWell {
        let well = UIColorWell()
        well.supportsAlpha = false
        if #available(iOS 26.0, *) {
            well.supportsEyedropper = false
        }
        well.selectedColor = UIColor(color)
        well.title = accessibilityLabel
        well.accessibilityLabel = accessibilityLabel
        well.accessibilityValue = well.selectedColor?.accessibilityName
        well.addTarget(
            context.coordinator,
            action: #selector(Coordinator.colorChanged(_:)),
            for: .valueChanged
        )
        well.accessibilityIdentifier = accessibilityIdentifier
        return well
    }

    func updateUIView(_ uiView: UIColorWell, context: Context) {
        let selectedColor = UIColor(color)
        if uiView.selectedColor != selectedColor {
            uiView.selectedColor = selectedColor
        }
        uiView.title = accessibilityLabel
        uiView.accessibilityLabel = accessibilityLabel
        uiView.accessibilityValue = uiView.selectedColor?.accessibilityName
        uiView.accessibilityIdentifier = accessibilityIdentifier
    }

    final class Coordinator: NSObject {
        private let parent: CategoryStatusColorPicker

        init(_ parent: CategoryStatusColorPicker) {
            self.parent = parent
        }

        @objc func colorChanged(_ sender: UIColorWell) {
            guard let selectedColor = sender.selectedColor else { return }
            parent.color = Color(selectedColor)
        }
    }
}

struct BudgetViewSettingsView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale: Locale
    @State private var isCategoryStatusColorPickerExpanded = false
    @State private var showingCategoryStatusColorInfo = false

    var body: some View {
        Form {
            // The Budget options menu keeps these as contextual shortcuts;
            // Settings exposes the same store-backed preferences so they can
            // also be managed outside the Budget tab.
            // #GH-332 is an issue for adding customizablity to this to prevent redundancy
            Section {
                Picker(String(localized: "View Style"), selection: $budgetStore.budgetDisplayStyle) {
                    Text(String(localized: "Clean")).tag(BudgetDisplayStyle.clean)
                    Text(String(localized: "Compact")).tag(BudgetDisplayStyle.compact)
                }

                Toggle(String(localized: "Group Totals"), isOn: $budgetStore.showGroupTotals)
                    .disabled(budgetStore.budgetDisplayStyle == .clean)

                Toggle(String(localized: "Status Filters"), isOn: $budgetStore.showBudgetCheckInStrip)
                Toggle(String(localized: "Hide Spent Categories"), isOn: $budgetStore.hideZeroBudgetCategories)
                Toggle(String(localized: "Category Status Dots"), isOn: $budgetStore.showCategoryStatusDots)
                Toggle(String(localized: "Budget Progress Bars"), isOn: $budgetStore.showBudgetProgressBars)
                Toggle(String(localized: "Overspent Badge"), isOn: $budgetStore.showOverspentBadge)

                DisclosureGroup(
                    isExpanded: $isCategoryStatusColorPickerExpanded
                ) {
                    ForEach(CategoryProgressState.allCases, id: \.self) { state in
                        HStack {
                            Text(state.statusText(locale: locale, bundle: .main))
                            Spacer()
                            CategoryStatusColorPicker(
                                color: Binding(
                                    get: { budgetStore.categoryStatusDotColor(for: state) },
                                    set: { budgetStore.setCategoryStatusDotColor($0, for: state) }
                                ),
                                accessibilityLabel: state.statusText(locale: locale, bundle: .main),
                                accessibilityIdentifier: "categoryStatusColorPicker.\(state.rawValue)"
                            )
                            .frame(width: 32, height: 32)

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
                        .accessibilityIdentifier("categoryStatusColorRow.\(state.rawValue)")
                    }
                } label: {
                    HStack(spacing: 8) {
                        Button {
                            showingCategoryStatusColorInfo = true
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Colour picker information"))
                        .accessibilityIdentifier("categoryStatusColorPickerInfo")

                        Text(String(localized: "Colour picker"))
                    }
                }
                .accessibilityIdentifier("categoryStatusColorPickerSection")
            } header: {
                Text(String(localized: "Presentation"))
            } footer: {
                if budgetStore.budgetDisplayStyle == .clean {
                    Text(String(localized: "Group Totals are available in Compact view."))
                }
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
            String(localized: "Colour picker"),
            isPresented: $showingCategoryStatusColorInfo
        ) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(String(localized: "Picked colour will be used for both category status dots and progress bars."))
        }
    }
}
