import Foundation
import Testing

@testable import Actuali

struct BackupPathTests {
    private func makeManager() -> (BudgetFileManager, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (BudgetFileManager(rootDirectoryForTesting: root), root)
    }

    @Test func backupPathsResolveUnderTestRoot() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = manager.backupsDirectory(for: "abc")
        #expect(dir.path.hasPrefix(root.path))
        #expect(dir.lastPathComponent == "backups")
        #expect(FileManager.default.fileExists(atPath: dir.path))

        #expect(manager.backupPath(for: "abc", name: "x.zip").lastPathComponent == "x.zip")
        #expect(manager.latestDatabasePath(for: "abc").lastPathComponent == "db.latest.sqlite")
        #expect(manager.latestMetadataPath(for: "abc").lastPathComponent == "metadata.latest.json")
    }

    @Test func archiveNameMatchesUpstreamFormat() {
        let name = BudgetFileManager.backupArchiveName(for: Date())
        #expect(name.range(
            of: #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.zip$"#,
            options: .regularExpression
        ) != nil)
    }

    @Test func tempNameMatchesUpstreamFormat() {
        let name = BudgetFileManager.backupTempName(now: Date(timeIntervalSince1970: 1.5))
        #expect(name == "db.1500.sqlite.tmp")
    }

    @Test func restoredOverNullsSyncFieldsAndInheritsIdentity() {
        let archived = BudgetMetadata(
            id: "b", budgetName: "n", cloudFileId: "old-cf", groupId: "g",
            resetClock: true, lastUploaded: "2026-08-01", encryptKeyId: "old-k"
        )
        let live = BudgetMetadata(
            id: "b", budgetName: "n2", cloudFileId: "live-cf", groupId: "g2",
            resetClock: nil, lastUploaded: nil, encryptKeyId: "live-k"
        )

        let restored = archived.restoredOver(live)
        #expect(restored.groupId == nil)
        #expect(restored.lastUploaded == nil)
        #expect(restored.cloudFileId == "live-cf")
        #expect(restored.encryptKeyId == "live-k")
        #expect(restored.id == "b")
        #expect(restored.budgetName == "n")   // archived name wins — it's the restored state
        #expect(restored.resetClock == true)

        // No live metadata (corrupt/missing file): fall back to the archive's.
        let orphan = archived.restoredOver(nil)
        #expect(orphan.cloudFileId == "old-cf")
        #expect(orphan.encryptKeyId == "old-k")
        #expect(orphan.groupId == nil)
    }
}
