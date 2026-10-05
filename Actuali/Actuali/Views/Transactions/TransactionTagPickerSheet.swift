import SwiftUI

/// Picks the tag to add to a batch of selected transactions: an existing tag
/// from the list, or a new name typed in the field.
struct TransactionTagPickerSheet: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    let onPick: (String) -> Void

    @State private var text = ""

    private var typedName: String {
        Tag.normalizeTagName(text)
    }

    private var typedNameIsInvalid: Bool {
        !typedName.isEmpty && !Tag.isValidTagName(text)
    }

    private var visibleTags: [Tag] {
        let tags = budgetStore.tags
            .filter { !$0.hidden && !$0.tombstone }
            .sorted { $0.tag.localizedCaseInsensitiveCompare($1.tag) == .orderedAscending }
        guard !typedName.isEmpty else { return tags }
        return tags.filter { $0.tag.localizedCaseInsensitiveContains(typedName) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField(ReportStrings.text("Tag Name", locale: locale), text: $text)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit(addTyped)
                            .accessibilityIdentifier("transactionTagPicker.field")
                        Button(ReportStrings.text("Add", locale: locale), action: addTyped)
                            .disabled(typedName.isEmpty || typedNameIsInvalid)
                            .accessibilityIdentifier("transactionTagPicker.add")
                    }
                } footer: {
                    if typedNameIsInvalid {
                        Text("Tag names cannot contain spaces or the # symbol.")
                            .foregroundStyle(.red)
                    }
                }

                if !visibleTags.isEmpty {
                    Section("Tags") {
                        ForEach(visibleTags) { tag in
                            Button {
                                pick(tag.tag)
                            } label: {
                                Text(tag.displayName)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(ReportStrings.text("Add Tag", locale: locale))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ReportStrings.text("Cancel", locale: locale)) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func addTyped() {
        guard !typedName.isEmpty, !typedNameIsInvalid else { return }
        pick(typedName)
    }

    private func pick(_ name: String) {
        onPick(name)
        dismiss()
    }
}
