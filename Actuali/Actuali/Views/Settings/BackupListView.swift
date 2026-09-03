import SwiftUI
import UniformTypeIdentifiers

struct BackupListView: View {
    @EnvironmentObject var budgetStore: BudgetStore
    @State private var pendingRestore: Backup?
    @State private var showingFolderPicker = false
    @State private var destinationName: String?
    @State private var lastMirroredDate: Date?
    @State private var lastMirrorError: String?
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

                            if let error = lastMirrorError {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle")
                                    Text("Mirror failed: \(error)")
                                }
                                .font(.caption2)
                                .foregroundStyle(.red)
                            } else if let date = lastMirroredDate {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle")
                                    Text("Mirrored \(Self.dateFormatter.string(from: date))")
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
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
                        Task {
                            await BackupDestinationManager.shared.clearDestination()
                            await refreshDestinationState()
                        }
                    }
                }
            } header: {
                Text("Destination")
            } footer: {
                if destinationName != nil {
                    Text("Backups are saved locally on this device and automatically mirrored to your chosen folder under Actuali/<budgetId>/.")
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
            await refreshDestinationState()
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
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder]
        ) { result in
            switch result {
            case .success(let url):
                guard url.startAccessingSecurityScopedResource() else {
                    destinationErrorMessage = BackupDestinationError.accessDenied.localizedDescription
                    return
                }
                defer { url.stopAccessingSecurityScopedResource() }
                do {
                    let bookmarkData = try url.bookmarkData(
                        options: [],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    let folderName = url.lastPathComponent
                    Task {
                        await BackupDestinationManager.shared.saveDestination(
                            bookmarkData: bookmarkData,
                            folderName: folderName
                        )
                        await refreshDestinationState()
                        guard let budgetId = budgetStore.currentBudgetId else { return }
                        let urls = archives.compactMap { backup -> URL? in
                            if case .archive(let id, _) = backup {
                                return budgetStore.backupFileURL(id)
                            }
                            return nil
                        }
                        await BackupDestinationManager.shared.mirrorExistingBackups(budgetId: budgetId, urls: urls)
                        await refreshDestinationState()
                    }
                } catch {
                    destinationErrorMessage = error.localizedDescription
                }
            case .failure(let error):
                destinationErrorMessage = error.localizedDescription
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

    private func refreshDestinationState() async {
        destinationName = await BackupDestinationManager.shared.destinationName
        lastMirroredDate = await BackupDestinationManager.shared.lastMirroredDate
        lastMirrorError = await BackupDestinationManager.shared.lastMirrorError
    }
}

#Preview {
    NavigationStack {
        BackupListView()
            .environmentObject(BudgetStore.previewInstance())
    }
}
