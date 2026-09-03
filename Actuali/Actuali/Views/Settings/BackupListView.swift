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
                            HStack {
                                Button {
                                    pendingRestore = backup
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(Self.dateFormatter.string(from: date))
                                            .foregroundStyle(.primary)
                                        Text("Tap to restore")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if let url = budgetStore.backupFileURL(id) {
                                    ShareLink(item: url) {
                                        Label("Export", systemImage: "square.and.arrow.up")
                                            .font(.subheadline)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if let url = budgetStore.backupFileURL(id) {
                                    ShareLink(item: url) {
                                        Label("Export", systemImage: "square.and.arrow.up")
                                    }
                                }
                            }
                            .contextMenu {
                                if let url = budgetStore.backupFileURL(id) {
                                    ShareLink(item: url) {
                                        Label("Export Backup", systemImage: "square.and.arrow.up")
                                    }
                                }
                                Button(role: .destructive) {
                                    pendingRestore = backup
                                } label: {
                                    Label("Restore Backup", systemImage: "arrow.counterclockwise")
                                }
                            }
                        }
                    }
                }
            } header: {
                if !archives.isEmpty {
                    Text("Available Backups")
                }
            } footer: {
                if !hasLatest && !archives.isEmpty {
                    Text("Backups are stored in Actuali's private app storage on this device. Tap Export to save to Files, iCloud Drive, or AirDrop. Tapping a backup restores it (your current data is saved first so you can revert).")
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
