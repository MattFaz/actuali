import SwiftUI

/// Editor for one row's note — a category (GH #131) or an account (GH #198) —
/// presented as a sheet from that row's detail view. Saving writes through to
/// Actual; a failure keeps the sheet open with the text intact so nothing the
/// user typed is lost.
///
/// One editor serves every annotated entity because Actual's `notes` table is
/// keyed by the annotated row's id: the only things that differ per entity are
/// the id to write and the name to put in the title.
struct NoteEditorView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.dismiss) private var dismiss

    /// The annotated row's id — a category id or an account id.
    let noteId: String
    /// Shown as the sheet's title, so the user can see what they're annotating.
    let title: String

    @State private var text: String
    @State private var isSaving = false
    @State private var saveError: String?
    @FocusState private var editorFocused: Bool

    init(noteId: String, title: String, note: String) {
        self.noteId = noteId
        self.title = title
        _text = State(initialValue: note)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 160)
                        .focused($editorFocused)
                        .accessibilityIdentifier("noteEditor")
                    // Links stay openable mid-edit (GH #190); the editor text
                    // itself has to remain plain to stay editable.
                    NoteLinkRows(text: text)
                } footer: {
                    if let saveError {
                        Text(saveError)
                            .foregroundStyle(.red)
                    } else {
                        Text(String(localized: "Syncs back to Actual, so it shows on every device on this budget. Clearing the text removes the note."))
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common.cancel")) { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(String(localized: "common.save")) {
                            Task { await save() }
                        }
                        .accessibilityIdentifier("saveNote")
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
            try await budgetStore.saveNote(
                id: noteId,
                note: EntityNote.normalizedForSave(text)
            )
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
        isSaving = false
    }
}

#Preview {
    NoteEditorView(
        noteId: "cat-1",
        title: "Food",
        note: "Cap at $400/mo — fuel comes out of Transport."
    )
    .environmentObject(BudgetStore.previewInstance())
}
