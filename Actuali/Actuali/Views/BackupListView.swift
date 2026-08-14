import SwiftUI

struct BackupListView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @State private var pendingRestore: Backup?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var hasLatest: Bool { budgetStore.backups.contains(where: \.isLatest) }
    private var archives: [Backup] { budgetStore.backups.filter { !$0.isLatest } }

    var body: some View {
        List {
            if hasLatest {
                Section {
                    Button("Revert to Original Version") {
                        Task { await budgetStore.revertToLatest() }
                    }
                } header: {
                    Text("You're Working From a Backup")
                } footer: {
                    Text("Reverting restores the budget exactly as it was before the backup was loaded.")
                }
            }

            Section {
                if archives.isEmpty {
                    Text("No backups yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(archives) { backup in
                        if case .archive(let id, let date) = backup {
                            Button {
                                pendingRestore = backup
                            } label: {
                                Text(Self.dateFormatter.string(from: date))
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if let url = budgetStore.backupFileURL(id) {
                                    ShareLink(item: url) {
                                        Label("Export", systemImage: "square.and.arrow.up")
                                    }
                                }
                            }
                        }
                    }
                }
            } footer: {
                if !hasLatest && !archives.isEmpty {
                    Text("Restoring a backup replaces the current budget. Your current data is saved first so you can revert. Swipe a backup to export it for import into Actual on the web or desktop.")
                }
            }
        }
        .navigationTitle("Backups")
        .task { await budgetStore.refreshBackups() }
        .confirmationDialog(
            "Restore this backup?",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                if let backup = pendingRestore {
                    Task { await budgetStore.restoreBackup(backup.id) }
                }
                pendingRestore = nil
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            if budgetStore.isConnected {
                Text("Restoring disconnects this budget from sync. To sync again, re-download the budget from your server — that replaces the restored data. Your current data is saved first so you can revert.")
            } else {
                Text("Your current data is saved first so you can revert.")
            }
        }
    }
}

#Preview {
    NavigationStack {
        BackupListView()
            .environmentObject(BudgetStore.previewInstance())
    }
}
