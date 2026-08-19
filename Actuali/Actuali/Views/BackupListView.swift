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
                    Button(String(localized: "Revert to Original Version")) {
                        Task { await budgetStore.revertToLatest() }
                    }
                } header: {
                    Text(String(localized: "You're Working From a Backup"))
                } footer: {
                    Text(String(localized: "Reverting restores the budget exactly as it was before the backup was loaded."))
                }
            }

            Section {
                if archives.isEmpty {
                    Text(String(localized: "No backups yet"))
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
                                        Label(String(localized: "Export"), systemImage: "square.and.arrow.up")
                                    }
                                }
                            }
                        }
                    }
                }
            } footer: {
                if !hasLatest && !archives.isEmpty {
                    Text(String(localized: "backupList.exportFooter"))
                }
            }
        }
        .navigationTitle(String(localized: "Backups"))
        .task { await budgetStore.refreshBackups() }
        .confirmationDialog(
            String(localized: "Restore this backup?"),
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Restore"), role: .destructive) {
                if let backup = pendingRestore {
                    Task { await budgetStore.restoreBackup(backup.id) }
                }
                pendingRestore = nil
            }
            Button(String(localized: "common.cancel"), role: .cancel) { pendingRestore = nil }
        } message: {
            if budgetStore.isConnected {
                Text(String(localized: "backupList.restoreConnected"))
            } else {
                Text(String(localized: "Your current data is saved first so you can revert."))
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
