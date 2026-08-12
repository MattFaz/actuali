import Foundation
import GRDB
import os

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "Backup")

/// The list item the Backups screen renders. Includes a timestamped archive, or the one-shot revert that exists only while the user is viewing a restored backup.
enum Backup: Identifiable, Equatable {
    case archive(id: String, date: Date)
    case latest

    var id: String {
        switch self {
        case .archive(let id, _): return id
        case .latest: return "db.latest.sqlite"
        }
    }

    var isLatest: Bool {
        if case .latest = self { return true }
        return false
    }
}

enum BackupError: LocalizedError {
    case snapshotFailed(Error)
    case archiveCreationFailed(Error)
    case backupNotFound(String)
    case restoreFailed(Error)

    var errorDescription: String? {
        switch self {
        case .snapshotFailed(let error):
            return "Couldn't snapshot the budget database: \(error.localizedDescription)"
        case .archiveCreationFailed(let error):
            return "Couldn't create the backup archive: \(error.localizedDescription)"
        case .backupNotFound(let id):
            return "Backup \(id) no longer exists"
        case .restoreFailed(let error):
            return "Couldn't restore the backup: \(error.localizedDescription)"
        }
    }
}

// MARK: - Backup Service

actor BackupService {
    private let fileManager: BudgetFileManager
    private let fm = FileManager.default

    init(fileManager: BudgetFileManager = .shared) {
        self.fileManager = fileManager
    }

    /// The snapshot is taken with VACUUM INTO instead of a raw file copy, so it is consistent under any journal mode and never touches the live db.
    /// Pass the open database when the budget is loaded; nil opens a temporary queue on the file (backing up a non-open budget).
    func makeBackup(budgetId: String, database: BudgetDatabase?, now: Date = Date()) async throws {
        // 1. Making a backup ends "viewing a backup": whatever is current
        //    becomes the new baseline. We remove the metadata companion too;
        //    upstream leaves it stale on disk (backups.ts:112-114) because
        //    only the db file acts as the flag — tidier to drop both.
        try? fm.removeItem(at: fileManager.latestDatabasePath(for: budgetId))
        try? fm.removeItem(at: fileManager.latestMetadataPath(for: budgetId))

        // 2. Ensure backups/ exists (backupsDirectory creates it) and sweep
        //    any .tmp a crashed backup left behind — invisible to the lister,
        //    but otherwise immortal.
        let backupsDir = fileManager.backupsDirectory(for: budgetId)
        if let leftovers = try? fm.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: nil) {
            for url in leftovers where url.lastPathComponent.hasSuffix(".sqlite.tmp") {
                try? fm.removeItem(at: url)
            }
        }

        // 3. Snapshot the live db to a temp file next to the archives.
        let tempDbURL = backupsDir.appendingPathComponent(BudgetFileManager.backupTempName(now: now))
        defer { try? fm.removeItem(at: tempDbURL) }

        do {
            if let database {
                try await database.snapshotDatabase(to: tempDbURL)
            } else {
                // Not BudgetDatabase: its init runs migrations, and taking a
                // backup must not mutate what it backs up.
                var config = Configuration()
                config.busyMode = .timeout(5)
                let queue = try DatabaseQueue(
                    path: fileManager.databasePath(for: budgetId).path, configuration: config
                )
                try await queue.writeWithoutTransaction { db in
                    try db.execute(sql: "VACUUM INTO ?", arguments: [tempDbURL.path])
                }
            }
        } catch {
            throw BackupError.snapshotFailed(error)
        }

        // 4. Strip CRDT state from the snapshot — backups are standalone and
        //    carry no sync history (backups.ts:135-138). Table-exists guards
        //    defend against unusual server files.
        do {
            let snapshotQueue = try DatabaseQueue(path: tempDbURL.path)
            try await snapshotQueue.write { db in
                if try db.tableExists("messages_crdt") {
                    try db.execute(sql: "DELETE FROM messages_crdt")
                }
                if try db.tableExists("messages_clock") {
                    try db.execute(sql: "DELETE FROM messages_clock")
                }
            }
        } catch {
            throw BackupError.snapshotFailed(error)
        }

        // 5. Zip the cleaned snapshot with a VERBATIM byte-copy of
        //    metadata.json — no Codable round-trip, so the archive never
        //    drops metadata keys this app doesn't model (plan D5).
        let archiveURL = fileManager.backupPath(
            for: budgetId, name: BudgetFileManager.backupArchiveName(for: now)
        )
        do {
            try fileManager.makeBudgetArchive(
                dbURL: tempDbURL,
                metadataURL: fileManager.metadataPath(for: budgetId),
                to: archiveURL
            )
        } catch {
            try? fm.removeItem(at: archiveURL)
            throw BackupError.archiveCreationFailed(error)
        }

        // 6. Prune to policy. (The .tmp cleanup is the defer above.)
        prune(budgetId: budgetId, today: now)
        logger.info("Backup created: \(archiveURL.lastPathComponent, privacy: .public)")
    }

    // MARK: - List

    /// Newest-first archives with the revert prepended while the user is viewing a backup.
    func availableBackups(budgetId: String) -> [Backup] {
        var result: [Backup] = []
        if fm.fileExists(atPath: fileManager.latestDatabasePath(for: budgetId).path) {
            result.append(.latest)
        }
        result.append(contentsOf: archiveList(budgetId: budgetId).map {
            .archive(id: $0.id, date: $0.date)
        })
        return result
    }

    private func archiveList(budgetId: String) -> [(id: String, date: Date)] {
        let backupsDir = fileManager.backupsDirectory(for: budgetId)
        let urls = (try? fm.contentsOfDirectory(
            at: backupsDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        return urls
            .filter { $0.pathExtension == "zip" }
            .map { url in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return (id: url.lastPathComponent, date: date)
            }
            .sorted { $0.date > $1.date }
    }

    // MARK: - Retention

    /// Within each local calendar day keep the first 3 (today) or first 1 (other days) of the given newest-first list
    /// then keep only the first 10 survivors. Returns the ids to delete.
    static func backupsToRemove(
        _ backups: [(id: String, date: Date)],
        today: Date,
        calendar: Calendar = .current
    ) -> [String] {
        var byDay: [Date: [(id: String, date: Date)]] = [:]
        for backup in backups {
            byDay[calendar.startOfDay(for: backup.date), default: []].append(backup)
        }

        let todayStart = calendar.startOfDay(for: today)
        var removed: [String] = []
        for (day, dayBackups) in byDay {
            let keep = day == todayStart ? 3 : 1
            removed.append(contentsOf: dayBackups.dropFirst(keep).map(\.id))
        }

        let remaining = backups.filter { !removed.contains($0.id) }
        removed.append(contentsOf: remaining.dropFirst(10).map(\.id))
        return removed
    }

    private func prune(budgetId: String, today: Date) {
        for id in Self.backupsToRemove(archiveList(budgetId: budgetId), today: today) {
            try? fm.removeItem(at: fileManager.backupPath(for: budgetId, name: id))
        }
    }
}
