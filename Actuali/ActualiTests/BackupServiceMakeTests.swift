import Foundation
import GRDB
import Testing

@testable import Actuali

struct BackupServiceMakeTests {
    /// A budget directory with a real db carrying CRDT tables + one data
    /// table, and a metadata.json — the minimum makeBackup touches.
    private func seedBudget(manager: BudgetFileManager, id: String) throws {
        let dir = manager.budgetDirectory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let dbQueue = try DatabaseQueue(path: manager.databasePath(for: id).path)
        try dbQueue.write { db in
            try db.execute(sql: "CREATE TABLE t (id TEXT PRIMARY KEY, note TEXT)")
            try db.execute(sql: "INSERT INTO t VALUES ('row1', 'original')")
            try db.execute(sql: """
                CREATE TABLE messages_crdt (id INTEGER PRIMARY KEY,
                    timestamp TEXT NOT NULL UNIQUE, dataset TEXT, row TEXT,
                    column TEXT, value BLOB)
                """)
            try db.execute(sql: "CREATE TABLE messages_clock (id INTEGER PRIMARY KEY, clock TEXT)")
            try db.execute(sql: """
                INSERT INTO messages_crdt (timestamp, dataset, row, column, value)
                VALUES ('2026-08-12T00:00:00.000Z-0000-0123456789abcdef', 't', 'row1', 'note', 'x')
                """)
            try db.execute(sql: "INSERT INTO messages_clock VALUES (1, '{}')")
            try db.execute(sql: "CREATE TABLE __migrations__ (id INTEGER PRIMARY KEY NOT NULL)")
            try db.execute(sql: "INSERT INTO __migrations__ (id) VALUES (1548957970627)") // real upstream id
            try db.execute(sql: "INSERT INTO __migrations__ (id) VALUES (1765518577216)") // Actuali-only
        }

        let metadata = BudgetMetadata(
            id: id, budgetName: "Seed", cloudFileId: "cf-1", groupId: "g-1",
            resetClock: nil, lastUploaded: "2026-08-01", encryptKeyId: nil
        )
        try JSONEncoder().encode(metadata).write(to: manager.metadataPath(for: id))
    }

    private func makeManager() -> (BudgetFileManager, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (BudgetFileManager(rootDirectoryForTesting: root), root)
    }

    @Test func backupStripsCRDTStateAndKeepsData() async throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBudget(manager: manager, id: "b1")

        let service = BackupService(fileManager: manager)
        try await service.makeBackup(budgetId: "b1", database: nil)

        let zips = try FileManager.default
            .contentsOfDirectory(at: manager.backupsDirectory(for: "b1"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "zip" }
        #expect(zips.count == 1)

        // No stray temp files survive.
        let tmps = try FileManager.default
            .contentsOfDirectory(at: manager.backupsDirectory(for: "b1"), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".sqlite.tmp") }
        #expect(tmps.isEmpty)

        // The archived db is standalone: CRDT tables empty, data intact.
        let extracted = try manager.extractBudgetArchive(at: zips[0])
        defer { try? FileManager.default.removeItem(at: extracted.databaseURL) }
        let queue = try DatabaseQueue(path: extracted.databaseURL.path)
        try await queue.read { db in
            let crdtCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt")
            let clockCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_clock")
            let note = try String.fetchOne(db, sql: "SELECT note FROM t WHERE id = 'row1'")
            #expect(crdtCount == 0)
            #expect(clockCount == 0)
            #expect(note == "original")
            #expect(try Int64.fetchAll(db, sql: "SELECT id FROM __migrations__") == [1548957970627])
        }

        // The live db is untouched.
        let liveQueue = try DatabaseQueue(path: manager.databasePath(for: "b1").path)
        let liveMessages = try await liveQueue.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messages_crdt")
        }
        #expect(liveMessages == 1)
        
        let liveMigrations = try await liveQueue.read {
        try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM __migrations__")
        }
        #expect(liveMigrations == 2)

        // Archived metadata is the verbatim live copy (groupId intact —
        // detachment happens on restore, not on backup).
        #expect(extracted.metadata.groupId == "g-1")
    }

    @Test func backupClearsRevertBaseline() async throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBudget(manager: manager, id: "b2")

        // Simulate "viewing a backup".
        try Data("old-db".utf8).write(to: manager.latestDatabasePath(for: "b2"))
        try Data("old-meta".utf8).write(to: manager.latestMetadataPath(for: "b2"))

        let service = BackupService(fileManager: manager)
        try await service.makeBackup(budgetId: "b2", database: nil)

        #expect(!FileManager.default.fileExists(atPath: manager.latestDatabasePath(for: "b2").path))
        #expect(!FileManager.default.fileExists(atPath: manager.latestMetadataPath(for: "b2").path))
    }

    @Test func backupWorksThroughOpenBudgetDatabase() async throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBudget(manager: manager, id: "b3")

        // The live-database path: snapshot via the open BudgetDatabase
        // (exercises snapshotDatabase / writeWithoutTransaction).
        let database = try BudgetDatabase(path: manager.databasePath(for: "b3"))
        let service = BackupService(fileManager: manager)
        try await service.makeBackup(budgetId: "b3", database: database)

        let zips = try FileManager.default
            .contentsOfDirectory(at: manager.backupsDirectory(for: "b3"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "zip" }
        #expect(zips.count == 1)
    }
    
    @Test func backupSweepsLeftoverArchiveTemp() async throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBudget(manager: manager, id: "b4")

        // A .zip.tmp a killed background backup left mid-write. It must never
        // be surfaced as a restorable backup, and the next backup sweeps it.
        let leftover = manager.backupsDirectory(for: "b4")
            .appendingPathComponent("2026-01-01_00-00-00.zip.tmp")
        try Data("truncated".utf8).write(to: leftover)

        let service = BackupService(fileManager: manager)
        let before = await service.availableBackups(budgetId: "b4")
        #expect(!before.contains { $0.id.hasSuffix(".tmp") })   // never listed

        try await service.makeBackup(budgetId: "b4", database: nil)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))   // swept

        // Exactly the one real archive remains, no temp residue.
        let remaining = try FileManager.default.contentsOfDirectory(
            at: manager.backupsDirectory(for: "b4"), includingPropertiesForKeys: nil
        )
        #expect(remaining.filter { $0.pathExtension == "zip" }.count == 1)
        #expect(remaining.filter { $0.lastPathComponent.hasSuffix(".tmp") }.isEmpty)
    }
}
