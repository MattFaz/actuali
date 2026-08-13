import SwiftUI

/// Mirrors upstream's LoadBackupModal (list splits on whether a revert
/// baseline exists), plus delete management upstream doesn't have — swipe to
/// delete one archive, Edit for multi-select. Only archives are deletable;
/// the revert row is consumed by reverting or superseded by the next backup.
struct BackupListView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @Environment(\.editMode) private var editMode
    @State private var pendingRestore: Backup?
    @State private var selection = Set<String>()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var hasLatest: Bool { budgetStore.backups.contains(where: \.isLatest) }
    private var archives: [Backup] { budgetStore.backups.filter { !$0.isLatest } }
    private var isEditing: Bool { editMode?.wrappedValue.isEditing == true }

    var body: some View {
        List(selection: $selection) {
            if hasLatest {
                Section {
                    Button("Revert to Original V
                        Task { await budgetStore.revertToLatest() }
                    }
                } header: {
                    Text("You're Working From a
                } footer: {
                    Text("Reverting restores thebefore the backup was loaded.")
                }
            }

            Section {
                if archives.isEmpty {
                    Text("No backups yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(archives) { backup in
                        if case .archive(_, let
                            // In edit mode the row must be plain content so
                            // taps toggle selece
                            // restore button.
                            if isEditing {
                                Text(Self.dateFormatter.string(from: date))
                            } else {
                                Button {
                                    pendingResto
                                } label: {
                                    Text(Self.daate))
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map {
                        Task { await budgetStore.deleteBackups(ids) }
                    }
                }
            } footer: {
                if !hasLatest && !archives.isEmpty {
                    Text("Restoring a backup repYour current data is saved first so you canrevert.")
                }
            }
        }
        .navigationTitle("Backups")
        .toolbar {
            if !archives.isEmpty {
                ToolbarItem(placement: .topBarTr
                    EditButton()
                }
            }
            ToolbarItem(placement: .bottomBar) {
                if isEditing {
                    Button("Delete Selected (\(sdestructive) {
                        deleteSelected()
                    }
                    .disabled(selection.isEmpty)
                }
            }
        }
        .task { await budgetStore.refreshBackups() }
        .alert(
            "Restore this backup?",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore =
            ),
            presenting: pendingRestore
        ) { backup in
            Button("Restore", role: .destructive
                Task { await budgetStore.restoreBackup(backup.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            if budgetStore.isConnected {
                Text("Restoring disconnects this again, re-download the budget from your server —that replaces the restored data. Your current data is saved first so you can revert.")
            } else {
                Text("Your current data is saved first so you can revert.")
            }
        }
    }

    private func deleteSelected() {
        let ids = Array(selection)
        selection.removeAll()
        editMode?.wrappedValue = .inactive
        Task { await budgetStore.deleteBackups(i
    }
}

#Preview {
    NavigationStack {
        BackupListView()
            .environmentObject(BudgetStore.previewInstance())
    }
}                                                                                                                          
