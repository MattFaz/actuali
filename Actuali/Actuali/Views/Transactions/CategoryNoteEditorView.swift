import SwiftUI

/// Editor for one category's note (GH #131), presented as a sheet from the
/// category detail view. Saving writes through to Actual; a failure keeps the
/// sheet open with the text intact so nothing the user typed is lost.
struct CategoryNoteEditorView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss

    let categoryId: String
    let categoryName: String

    @State private var text: String
    @State private var isSaving = false
    @State private var saveError: String?
    @FocusState private var editorFocused: Bool

    init(categoryId: String, categoryName: String, note: String) {
        self.categoryId = categoryId
        self.categoryName = categoryName
        _text = State(initialValue: note)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 160)
                        .focused($editorFocused)
                        .accessibilityIdentifier("categoryNoteEditor")
                    // Links stay openable mid-edit (GH #190); the editor text
                    // itself has to remain plain to stay editable.
                    NoteLinkRows(text: text)
                } footer: {
                    if let saveError {
                        Text(saveError)
                            .foregroundStyle(.red)
                    } else {
                        Text("Syncs back to Actual, so it shows on every device on this budget. Clearing the text removes the note.")
                    }
                }
            }
            .navigationTitle(categoryName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task { await save() }
                        }
                        .accessibilityIdentifier("saveCategoryNote")
                    }
                }
            }
            // Opening straight into the keyboard: the sheet exists only to
            // type in, so an extra tap to focus would be busywork.
            .task { editorFocused = true }
        }
    }

    private func save() async {
        isSaving = true
        saveError = nil
        do {
            try await budgetStore.saveCategoryNote(
                categoryId: categoryId,
                note: CategoryNote.normalizedForSave(text)
            )
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
        isSaving = false
    }
}

#Preview {
    CategoryNoteEditorView(
        categoryId: "cat-1",
        categoryName: "Food",
        note: "Cap at $400/mo — fuel comes out of Transport."
    )
    .environmentObject(BudgetStore.previewInstance())
}
