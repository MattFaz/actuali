import SwiftUI

/// The Budget tab's creation forms (GH #284). Actual's web UI hangs "Add
/// group" off the bottom of the budget table and "Add category" off each
/// group header; neither has room on a phone, so both live behind the tab's
/// + button — which is why the category form carries a group picker instead
/// of inheriting the group it was opened from.
enum NewBudgetItem: String, Identifiable {
    case category
    case group

    var id: String {
        rawValue
    }
}

struct CategoryGroupSheet: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss

    let group: CategoryGroup?
    let month: String

    @State private var name: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(group: CategoryGroup? = nil, month: String = "") {
        self.group = group
        self.month = month
        _name = State(initialValue: group?.name ?? "")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var title: LocalizedStringKey {
        group == nil ? "New Group" : "Rename Group"
    }

    private var actionTitle: LocalizedStringKey {
        group == nil ? "Create" : "Save"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Group Name", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("categoryGroupEditor.name")
                } footer: {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    } else if group == nil {
                        Text("The group is added below your existing ones, ready for categories.")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle) {
                        Task { await submit() }
                    }
                    .disabled(isSaving || trimmedName.isEmpty)
                }
            }
            .disabled(isSaving)
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func submit() async {
        // A second tap can race the button's .disabled(isSaving) re-render
        // and enqueue a second Task — bail so one tap means one group.
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil

        do {
            if let group {
                guard trimmedName != group.name else {
                    dismiss()
                    return
                }
                try await budgetStore.renameCategoryGroup(
                    id: group.id,
                    name: name,
                    month: month
                )
            } else {
                try await budgetStore.createCategoryGroup(name: name)
            }
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

struct CategoryDeletionRequest: Identifiable {
    enum Kind: Equatable {
        case category
        case group
    }

    let id: String
    let name: String
    let categoryIds: [String]
    let isIncome: Bool
    let kind: Kind
    let month: String
    let requiresTransfer: Bool

    var isGroup: Bool {
        kind == .group
    }
}

private struct CategoryTransferGroupOption: Identifiable {
    let group: CategoryGroup
    let categories: [Category]

    var id: String {
        group.id
    }
}

/// Actual-style confirm-delete sheet. A destination is mandatory whenever the
/// source contains transaction history or has a non-zero budget in any month.
struct CategoryDeletionSheet: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss

    let request: CategoryDeletionRequest

    @State private var transferCategoryId: String?
    @State private var requiresTransfer: Bool
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(request: CategoryDeletionRequest) {
        self.request = request
        _requiresTransfer = State(initialValue: request.requiresTransfer)
    }

    private var selectableGroups: [CategoryTransferGroupOption] {
        let excludedIds = Set(request.categoryIds)
        return budgetStore.categoryGroups
            .filter { $0.isIncome == request.isIncome }
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { group in
                let categories = group.categories.filter { !excludedIds.contains($0.id) }
                guard !categories.isEmpty else { return nil }
                return CategoryTransferGroupOption(group: group, categories: categories)
            }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(request.name)
                        .font(.headline)
                    if requiresTransfer {
                        Text("All existing transactions and budget balances will be transferred to the selected category before deletion.")
                    } else {
                        Text("Are you sure you want to delete this item?")
                    }
                }

                if requiresTransfer {
                    Section("Transfer to:") {
                        Picker("Category", selection: $transferCategoryId) {
                            Text("Select a category").tag(String?.none)
                            ForEach(selectableGroups) { option in
                                Section(option.group.name) {
                                    ForEach(option.categories) { category in
                                        Text(category.name).tag(Optional(category.id))
                                    }
                                }
                            }
                        }
                        .accessibilityIdentifier("categoryDelete.transferTo")
                        .onChange(of: transferCategoryId) { _, _ in
                            errorMessage = nil
                        }
                    }

                    if selectableGroups.isEmpty {
                        Text("No eligible categories are available to receive the transfer.")
                            .foregroundStyle(.red)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(request.isGroup ? LocalizedStringKey("Delete Group") : LocalizedStringKey("Delete Category"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Delete", role: .destructive) {
                        Task { await submit() }
                    }
                    .accessibilityIdentifier("categoryDelete.confirm")
                    .disabled(isSaving || (requiresTransfer && (transferCategoryId == nil || selectableGroups.isEmpty)))
                }
            }
            .disabled(isSaving)
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func submit() async {
        guard !isSaving else { return }
        guard !requiresTransfer || transferCategoryId != nil else {
            errorMessage = String(localized: "You must select a category")
            return
        }

        isSaving = true
        errorMessage = nil
        do {
            let targetId = requiresTransfer ? transferCategoryId : nil
            if request.isGroup {
                try await budgetStore.deleteCategoryGroup(
                    id: request.id,
                    transferToId: targetId,
                    month: request.month
                )
            } else {
                try await budgetStore.deleteCategory(
                    id: request.id,
                    transferToId: targetId,
                    month: request.month
                )
            }
            dismiss()
        } catch BudgetStoreError.missingTransferDestination {
            // The data may have changed since the parent view's preflight. Keep
            // this sheet open and expose the destination picker without forcing
            // the user to cancel and restart deletion.
            requiresTransfer = true
            transferCategoryId = nil
            errorMessage = BudgetStoreError.missingTransferDestination.localizedDescription
            isSaving = false
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}

#Preview("New Group") {
    CategoryGroupSheet()
        .environmentObject(BudgetStore.previewInstance())
}

#Preview("New Category") {
    NewCategorySheet(groupId: "")
        .environmentObject(BudgetStore.previewInstance())
}
