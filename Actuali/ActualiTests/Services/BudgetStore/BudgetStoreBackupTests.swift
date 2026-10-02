import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreBackupTests {
    private func seedToyBudget(manager: BudgetFileManager, id: String) throws {
        let dir = manager.budgetDirectory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbQueue = try DatabaseQueue(path: manager.databasePath(for: id).path)
        try dbQueue.write { db in
            try db.execute(sql: "CREATE TABLE t (id TEXT PRIMARY KEY, note TEXT)")
            try db.execute(sql: "INSERT INTO t VALUES ('row1', 'original')")
        }
        try JSONEncoder().encode(BudgetMetadata(
            id: id, budgetName: "Seed", cloudFileId: "cf-1", groupId: "g-1",
            resetClock: nil, lastUploaded: nil, encryptKeyId: nil
        )).write(to: manager.metadataPath(for: id))
    }

    @Test func makeBackupNowPublishesList() async throws {
        let (store, manager, root) = makeFileBackedStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedToyBudget(manager: manager, id: "b")
        store.currentBudgetId = "b"

        await store.makeBackupNow()
        #expect(store.backups.count == 1)
        #expect(store.backups.allSatisfy { !$0.isLatest })
    }

    @Test func backupOnBackgroundSkipsWhileViewingABackup() throws {
        let (store, manager, root) = makeFileBackedStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedToyBudget(manager: manager, id: "b")
        store.currentBudgetId = "b"
        try store.configureForTesting(
            database: BudgetDatabase(path: manager.databasePath(for: "b")),
            syncClient: SyncClient(serverClient: ActualServerClient(), nodeId: "0123456789abcdef")
        )

        // Viewing a backup: the automatic trigger must not clear the baseline.
        try Data("baseline".utf8).write(to: manager.latestDatabasePath(for: "b"))
        // The viewing-a-backup guard returns before any Task is spawned, so there is nothing to await.
        store.backupOnBackground()
        #expect(FileManager.default.fileExists(atPath: manager.latestDatabasePath(for: "b").path))
        let zips = try FileManager.default
            .contentsOfDirectory(at: manager.backupsDirectory(for: "b"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "zip" }
        #expect(zips.isEmpty)
    }

    /// A restored budget (cloud identity kept, groupId nulled) must not get a
    /// sync client: the server still has the old group, so any sync would earn
    /// a 400 file-has-reset and an endless retry loop.
    @Test func loadSkipsSyncConfigurationWhenDetachedByRestore() async throws {
        let (store, manager, root) = makeFileBackedStore()
        defer { try? FileManager.default.removeItem(at: root) }

        // loadLocalBudget reads the full budget schema, not just one table.
        try seedBudget(id: "b", in: manager)

        // Attached metadata (groupId present): sync configures as usual.
        await store.loadLocalBudget("b")
        #expect(store.error == nil)
        #expect(!store.syncDetachedByRestore)
        #expect(store.isSyncConfiguredForTesting)

        // Detached metadata, as restoredOver() writes it: reload must drop
        // the stale client, not just skip creating a new one.
        try JSONEncoder().encode(BudgetMetadata(
            id: "b", budgetName: "Seed", cloudFileId: "cf-1", groupId: nil,
            resetClock: nil, lastUploaded: nil, encryptKeyId: nil
        )).write(to: manager.metadataPath(for: "b"))
        await store.loadLocalBudget("b")
        #expect(store.syncDetachedByRestore)
        #expect(!store.isSyncConfiguredForTesting)
    }

    @Test func backupFileURLPointsAtImportableArchive() async throws {
        let (store, manager, root) = makeFileBackedStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedToyBudget(manager: manager, id: "b")
        store.currentBudgetId = "b"

        await store.makeBackupNow()
        let id = try #require(store.backups.first(where: { !$0.isLatest })?.id)

        // The exported URL is a real file and a valid Actual-import archive.
        let url = try #require(store.backupFileURL(id))
        #expect(FileManager.default.fileExists(atPath: url.path))
        let extracted = try manager.extractBudgetArchive(at: url)
        defer { try? FileManager.default.removeItem(at: extracted.databaseURL) }
        #expect(extracted.metadata.id == "b")
    }
}
