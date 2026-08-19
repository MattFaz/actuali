import SwiftUI

/// The Budget tab's creation forms (GH #284). Actual's web UI hangs "Add
/// group" off the bottom of the budget table and "Add category" off each
/// group header; neither has room on a phone, so both live behind the tab's
/// + button — which is why the category form carries a group picker instead
/// of inheriting the group it was opened from.
enum NewBudgetItem: String, Identifiable {
    case category
    case group

    var id: String { rawValue }
}

struct NewCategoryGroupSheet: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Group Name", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                } footer: {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    } else {
                        Text("The group is added below your existing ones, ready for categories.")
                    }
                }
            }
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await create() }
                    }
                    .disabled(isSaving || trimmedName.isEmpty)
                }
            }
            .disabled(isSaving)
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func create() async {
        // A second tap can race the button's .disabled(isSaving) re-render
        // and enqueue a second Task — bail so one tap means one group.
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil

        do {
            try await budgetStore.createCategoryGroup(name: name)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}

struct NewCategorySheet: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var groupId: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    /// `groupId` is the group the picker starts on — the Budget tab passes
    /// the first one it draws.
    init(groupId: String) {
        _groupId = State(initialValue: groupId)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Hidden groups are left out for the same reason the budget table
    /// doesn't draw them — a category filed there would be invisible.
    private var selectableGroups: [CategoryGroup] {
        budgetStore.categoryGroups
            .filter { !$0.hidden }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Category Name", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                } footer: {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Picker("Group", selection: $groupId) {
                        ForEach(selectableGroups) { group in
                            Text(group.name).tag(group.id)
                        }
                    }
                } footer: {
                    Text("The category is added at the top of its group, the same as the web app.")
                }
            }
            .navigationTitle("New Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await create() }
                    }
                    .disabled(isSaving || trimmedName.isEmpty || groupId.isEmpty)
                }
            }
            .disabled(isSaving)
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func create() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil

        do {
            try await budgetStore.createCategory(name: name, groupId: groupId)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}

#Preview("New Group") {
    NewCategoryGroupSheet()
        .environmentObject(BudgetStore.previewInstance())
}

#Preview("New Category") {
    NewCategorySheet(groupId: "")
        .environmentObject(BudgetStore.previewInstance())
}
