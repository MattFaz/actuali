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
    case snapshotFailed(any Error)
    case archiveCreationFailed(any Error)
    case backupNotFound(String)
    case restoreFailed(any Error)

    var errorDescription: String? {
        switch self {
        case .snapshotFailed(let error):
            return String(localized: "Couldn't snapshot the budget database: \(error.localizedDescription)")
        case .archiveCreationFailed(let error):
            return String(localized: "Couldn't create the backup archive: \(error.localizedDescription)")
        case .backupNotFound(let id):
            return String(localized: "Backup \(id) no longer exists")
        case .restoreFailed(let error):
            return String(localized: "Couldn't restore the backup: \(error.localizedDescription)")
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
        // 1. Ensure backups folder exist (backupsDirectory creates it) and sweep
        //    any .tmp a crashed backup left behind.
        let backupsDir = fileManager.backupsDirectory(for: budgetId)
        if let leftovers = try? fm.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: nil) {
            for url in leftovers where url.lastPathComponent.hasSuffix(".tmp") {
                try? fm.removeItem(at: url)
            }
        }

        // 2. Snapshot the live db to a temp file next to the archives.
        let tempDbURL = backupsDir.appendingPathComponent(BudgetFileManager.backupTempName(now: now))
        defer { try? fm.removeItem(at: tempDbURL) }

        do {
            try await snapshotLiveDatabase(budgetId: budgetId, database: database, to: tempDbURL)
        } catch {
            throw BackupError.snapshotFailed(error)
        }

        // 3. Strip CRDT state from the snapshot as backups are standalone and
        //    carry no sync history. Table guards defend against unusual server files.
        do {
            let snapshotQueue = try DatabaseQueue(path: tempDbURL.path)
            try await snapshotQueue.write { db in
                if try db.tableExists("messages_crdt") {
                    try db.execute(sql: "DELETE FROM messages_crdt")
                }
                if try db.tableExists("messages_clock") {
                    try db.execute(sql: "DELETE FROM messages_clock")
                }
                // Strip Actuali's own migration bookkeeping: Actual's import
                // rejects any db whose __migrations__ holds ids it doesn't
                // ship. Without these rows the snapshot looks exactly like a
                // file an upstream client migrated; restoring it in Actuali
                // simply re-records the ids (the guards see the schema
                // already exists and skip the SQL).
                if try db.tableExists("__migrations__") {
                    let ids = BudgetDatabase.actualiOnlyMigrationIds
                        .map(String.init)
                        .joined(separator: ", ")
                    try db.execute(sql: "DELETE FROM __migrations__ WHERE id IN (\(ids))")
                }
            }
        } catch {
            throw BackupError.snapshotFailed(error)
        }

        // 4. Zip the cleaned snapshot with a VERBATIM byte-copy of metadata.json.
        // No Codable round-trip, so the archive never drops metadata keys this app doesn't model.
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

        // 5. Making a backup ends "viewing a backup": whatever is current
        //    becomes the new baseline. Only now that the archive has landed —
        //    a failed backup must not cost the user the revert option.
        try? fm.removeItem(at: fileManager.latestDatabasePath(for: budgetId))
        try? fm.removeItem(at: fileManager.latestMetadataPath(for: budgetId))

        // 6. Prune existing backups
        prune(budgetId: budgetId, today: now)
        logger.info("Backup created: \(archiveURL.lastPathComponent, privacy: .public)")
    }

    /// Consistent snapshot of the live db via VACUUM INTO — serialized on the
    /// open database's write queue when one is passed, so it can never race a
    /// concurrent write (a raw file copy of a SQLite db mid-transaction can be
    /// torn). Nil opens a temporary queue on the file (non-open budget); not
    /// BudgetDatabase, whose init runs migrations, and a snapshot must not
    /// mutate what it captures.
    private func snapshotLiveDatabase(
        budgetId: String, database: BudgetDatabase?, to url: URL
    ) async throws {
        if let database {
            try await database.snapshotDatabase(to: url)
        } else {
            var config = Configuration()
            config.busyMode = .timeout(5)
            let queue = try DatabaseQueue(
                path: fileManager.databasePath(for: budgetId).path, configuration: config
            )
            try await queue.writeWithoutTransaction { db in
                try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
            }
        }
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
    
    // MARK: - Restore

    /// Restore backupId over the live files, first snapshotting the current state so the user can revert.
    /// The caller (BudgetStore) MUST have dropped its database/sync references first and must
    /// reopen/reload afterwards; pass the database it held so the baseline snapshot serializes
    /// with any write still in flight on that queue.
    func loadBackup(budgetId: String, backupId: String, database: BudgetDatabase?) async throws {
        let liveDb = fileManager.databasePath(for: budgetId)
        let liveMetadata = fileManager.metadataPath(for: budgetId)
        let latestDb = fileManager.latestDatabasePath(for: budgetId)
        let latestMetadata = fileManager.latestMetadataPath(for: budgetId)

        do {
            if backupId == Backup.latest.id {
                // Case A — revert: put the baseline back and consume it. The baseline metadata still
                // carries the original groupId, so sync resumes automatically once the store reopens.
                // Both halves must exist — a half-pair from a crash is not a
                // baseline (the creation order below makes the db the marker).
                guard fm.fileExists(atPath: latestDb.path),
                      fm.fileExists(atPath: latestMetadata.path) else {
                    throw BackupError.backupNotFound(backupId)
                }
                try replaceFile(at: liveDb, with: latestDb)
                try replaceFile(at: liveMetadata, with: latestMetadata)
                try fm.removeItem(at: latestDb)
                try fm.removeItem(at: latestMetadata)
            } else {
                // Case B — a real archive.
                let archiveURL = fileManager.backupPath(for: budgetId, name: backupId)
                guard fm.fileExists(atPath: archiveURL.path) else {
                    throw BackupError.backupNotFound(backupId)
                }

                // First restore of this viewing session: preserve current state
                // as the revert baseline. Metadata first, db last — the db is
                // the existence marker everything keys on, so a crash between
                // the two writes leaves only a metadata orphan, swept here.
                if !fm.fileExists(atPath: latestDb.path) {
                    try? fm.removeItem(at: latestMetadata)
                    try fm.copyItem(at: liveMetadata, to: latestMetadata)
                    try await snapshotLiveDatabase(
                        budgetId: budgetId, database: database, to: latestDb
                    )
                }

                let extracted = try fileManager.extractBudgetArchive(at: archiveURL)
                defer { try? fm.removeItem(at: extracted.databaseURL) }

                let liveMeta = (try? Data(contentsOf: liveMetadata))
                    .flatMap { try? JSONDecoder().decode(BudgetMetadata.self, from: $0) }
                let restored = extracted.metadata.restoredOver(liveMeta)

                removeSQLiteSidecars(for: liveDb)
                try fm.removeItem(at: liveDb)
                try fm.moveItem(at: extracted.databaseURL, to: liveDb)
                try JSONEncoder().encode(restored).write(to: liveMetadata)
            }
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.restoreFailed(error)
        }
    }

    private func replaceFile(at destination: URL, with source: URL) throws {
        removeSQLiteSidecars(for: destination)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }

    private func removeSQLiteSidecars(for dbURL: URL) {
        // -journal for DELETE mode (the app's default), -wal/-shm in case a
        // snapshot or older file carried them. A stale sidecar left next to the
        // swapped-in database would be reinterpreted against the wrong file.
        for suffix in ["-journal", "-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: dbURL.path + suffix))
        }
    }
}
