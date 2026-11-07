import SwiftUI

struct CategoryStatusColorPickerSheet: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var showingCategoryStatusColorInfo = false

    var body: some View {
        NavigationStack {
            Form {
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
                }
            }
            .navigationTitle(String(localized: "Color picker"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("budgetOptions.colorPickerDone")
                }
            }
        }
        .presentationDetents([.large])
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
