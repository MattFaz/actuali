import SwiftUI

struct BackupListView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @State private var pendingRestore: Backup?
    @State private var showingFolderPicker = false
    @State private var destinationName: String? = BackupDestinationManager.shared.destinationName
    @State private var destinationErrorMessage: String?

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
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Backup Location")
                            .foregroundStyle(.primary)
                        if let name = destinationName {
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                Text(name)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else {
                            Text("Default (App Storage)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(destinationName == nil ? "Choose Folder" : "Change") {
                        showingFolderPicker = true
                    }
                    .buttonStyle(.bordered)
                }

                if destinationName != nil {
                    Button("Reset to Default", role: .destructive) {
                        BackupDestinationManager.shared.clearDestination()
                        destinationName = nil
                    }
                }
            } header: {
                Text("Destination")
            } footer: {
                if destinationName != nil {
                    Text("Backups are saved locally on this device and automatically mirrored to your chosen folder.")
                } else {
                    Text("Backups are stored safely in Actuali's private app storage. You can choose a custom folder (such as an iCloud Drive folder) to automatically mirror every backup there.")
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
        .task {
            destinationName = BackupDestinationManager.shared.destinationName
            await budgetStore.refreshBackups()
        }
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
        .sheet(isPresented: $showingFolderPicker) {
            FolderPicker { url in
                do {
                    try BackupDestinationManager.shared.saveDestination(from: url)
                    destinationName = BackupDestinationManager.shared.destinationName
                    let urls = archives.compactMap { backup -> URL? in
                        if case .archive(let id, _) = backup {
                            return budgetStore.backupFileURL(id)
                        }
                        return nil
                    }
                    Task {
                        await BackupDestinationManager.shared.mirrorExistingBackups(urls: urls)
                    }
                } catch {
                    destinationErrorMessage = error.localizedDescription
                }
            }
        }
        .alert(
            "Couldn't Set Backup Folder",
            isPresented: Binding(
                get: { destinationErrorMessage != nil },
                set: { if !$0 { destinationErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { destinationErrorMessage = nil }
        } message: {
            if let message = destinationErrorMessage {
                Text(message)
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
