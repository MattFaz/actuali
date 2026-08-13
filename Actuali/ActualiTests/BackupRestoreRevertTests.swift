import Foundation
import GRDB
import Testing

@testable import Actuali

struct BackupRestoreRevertTests {
    private func makeManager() -> (BudgetFileManager, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (BudgetFileManager(rootDirectoryForTesting: root), root)
    }

    private func seedBudget(manager: BudgetFileManager, id: String, note: String) throws {
        let dir = manager.budgetDirectory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbQueue = try DatabaseQueue(path: manager.databasePath(for: id).path)
        try dbQueue.write { db in
            try db.execute(sql: "CREATE TABLE t (id TEXT PRIMARY KEY, note TEXT)")
            try db.execute(sql: "INSERT INTO t VALUES ('row1', ?)", arguments: [note])
            try db.execute(sql: "CREATE TABLE messages_crdt (id INTEGER PRIMARY KEY, timestamp TEXT)")
            try db.execute(sql: "CREATE TABLE messages_clock (id INTEGER PRIMARY KEY, clock TEXT)")
        }
        try JSONEncoder().encode(BudgetMetadata(
            id: id, budgetName: "Seed", cloudFileId: "cf-1", groupId: "g-1",
            resetClock: nil, lastUploaded: "2026-08-01", encryptKeyId: "k-1"
        )).write(to: manager.metadataPath(for: id))
    }

    private func note(manager: BudgetFileManager, id: String) throws -> String? {
        let queue = try DatabaseQueue(path: manager.databasePath(for: id).path)
        return try queue.read { try String.fetchOne($0, sql: "SELECT note FROM t WHERE id = 'row1'") }
    }

    private func metadata(manager: BudgetFileManager, id: String) throws -> BudgetMetadata {
        try JSONDecoder().decode(
            BudgetMetadata.self, from: Data(contentsOf: manager.metadataPath(for: id))
        )
    }

    @Test func restoreDetachesAndRevertRestoresByteIdentity() async throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBudget(manager: manager, id: "b", note: "backup-state")

        let service = BackupService(fileManager: manager)
        try await service.makeBackup(budgetId: "b", database: nil)
        let archiveId = try #require(
            await service.availableBackups(budgetId: "b").first(where: { !$0.isLatest })?.id
        )

        // The budget moves on after the backup was taken.
        let dbQueue = try DatabaseQueue(path: manager.databasePath(for: "b").path)
        try await dbQueue.write { try $0.execute(sql: "UPDATE t SET note = 'current-state'") }
        let preRestoreDbBytes = try Data(contentsOf: manager.databasePath(for: "b"))
        let preRestoreMetaBytes = try Data(contentsOf: manager.metadataPath(for: "b"))

        // Restore the archive.
        try await service.loadBackup(budgetId: "b", backupId: archiveId)

        #expect(try note(manager: manager, id: "b") == "backup-state")
        let restoredMeta = try metadata(manager: manager, id: "b")
        #expect(restoredMeta.groupId == nil)              // detached
        #expect(restoredMeta.lastUploaded == nil)
        #expect(restoredMeta.cloudFileId == "cf-1")       // identity kept
        #expect(restoredMeta.encryptKeyId == "k-1")
        #expect(FileManager.default.fileExists(atPath: manager.latestDatabasePath(for: "b").path))

        // The list shows the revert head first.
        let listed = await service.availableBackups(budgetId: "b")
        #expect(listed.first?.isLatest == true)

        // Revert: byte-identical original, baseline consumed, sync resumable.
        try await service.loadBackup(budgetId: "b", backupId: Backup.latest.id)
        #expect(try Data(contentsOf: manager.databasePath(for: "b")) == preRestoreDbBytes)
        #expect(try Data(contentsOf: manager.metadataPath(for: "b")) == preRestoreMetaBytes)
        #expect(try metadata(manager: manager, id: "b").groupId == "g-1")
        #expect(!FileManager.default.fileExists(atPath: manager.latestDatabasePath(for: "b").path))
        #expect(!FileManager.default.fileExists(atPath: manager.latestMetadataPath(for: "b").path))
    }

    @Test func secondRestoreKeepsOriginalBaseline() async throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBudget(manager: manager, id: "b", note: "v1")

        let service = BackupService(fileManager: manager)
        try await service.makeBackup(budgetId: "b", database: nil, now: Date())
        let dbQueue = try DatabaseQueue(path: manager.databasePath(for: "b").path)
        try await dbQueue.write { try $0.execute(sql: "UPDATE t SET note = 'v2'") }
        try await service.makeBackup(budgetId: "b", database: nil, now: Date().addingTimeInterval(1))
        try await dbQueue.write { try $0.execute(sql: "UPDATE t SET note = 'v3'") }

        let archives = await service.availableBackups(budgetId: "b").filter { !$0.isLatest }
        #expect(archives.count == 2)

        // Restore twice in a row: the baseline must stay the ORIGINAL (v3)
        // state — the snapshot happens once per viewing session.
        try await service.loadBackup(budgetId: "b", backupId: archives[1].id) // oldest → v1
        try await service.loadBackup(budgetId: "b", backupId: archives[0].id) // newer → v2
        #expect(try note(manager: manager, id: "b") == "v2")

        try await service.loadBackup(budgetId: "b", backupId: Backup.latest.id)
        #expect(try note(manager: manager, id: "b") == "v3")
    }

    @Test func restoreOfMissingBackupThrows() async throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBudget(manager: manager, id: "b", note: "v1")

        let service = BackupService(fileManager: manager)
        await #expect(throws: BackupError.self) {
            try await service.loadBackup(budgetId: "b", backupId: "2026-01-01_00-00-00.zip")
        }
    }

    @Test func reimportPreservesBackupsAndClearsBaseline() async throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBudget(manager: manager, id: "b", note: "v1")

        let service = BackupService(fileManager: manager)
        try await service.makeBackup(budgetId: "b", database: nil)
        try Data("baseline".utf8).write(to: manager.latestDatabasePath(for: "b"))

        // Build a server-download zip for the SAME budget id and re-import.
        let stagingDir = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let stagedDb = stagingDir.appendingPathComponent("db.sqlite")
        let queue = try DatabaseQueue(path: stagedDb.path)
        try await queue.write { try $0.execute(sql: "CREATE TABLE t (id TEXT)") }
        let stagedMeta = stagingDir.appendingPathComponent("metadata.json")
        try JSONEncoder().encode(BudgetMetadata(
            id: "b", budgetName: "Server Copy", cloudFileId: nil, groupId: nil,
            resetClock: nil, lastUploaded: nil, encryptKeyId: nil
        )).write(to: stagedMeta)
        let downloadZip = stagingDir.appendingPathComponent("download.zip")
        try manager.makeBudgetArchive(dbURL: stagedDb, metadataURL: stagedMeta, to: downloadZip)

        _ = try await manager.importBudget(
            from: Data(contentsOf: downloadZip), fileId: "cf-1", groupId: "g-new"
        )

        // Backups survived the re-download; the revert baseline did not.
        let backups = await service.availableBackups(budgetId: "b")
        #expect(backups.contains { !$0.isLatest })
        #expect(!backups.contains { $0.isLatest })
        #expect(!FileManager.default.fileExists(atPath: manager.latestDatabasePath(for: "b").path))
    }
}
