import Foundation
import Testing

@testable import Actuali

struct BackupDestinationManagerTests {
    private func makeManager() -> (BackupDestinationManager, UserDefaults, String) {
        let suiteName = "test.backup.destination.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let manager = BackupDestinationManager(userDefaults: defaults)
        return (manager, defaults, suiteName)
    }

    @Test func defaultStateHasNoCustomDestination() {
        let (manager, defaults, suiteName) = makeManager()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(manager.destinationName == nil)
        #expect(!manager.isCustomDestinationConfigured)
        #expect(manager.lastMirroredDate == nil)
        #expect(manager.lastMirrorError == nil)
    }

    @Test func clearDestinationRemovesKeys() async {
        let (manager, defaults, suiteName) = makeManager()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("FakeBookmark".data(using: .utf8), forKey: BackupDestinationManager.bookmarkKey)
        defaults.set("my-fav-backup", forKey: BackupDestinationManager.nameKey)
        defaults.set(Date(), forKey: BackupDestinationManager.lastMirroredDateKey)
        defaults.set("Mock Error", forKey: BackupDestinationManager.lastMirrorErrorKey)

        #expect(manager.destinationName == "my-fav-backup")
        #expect(manager.isCustomDestinationConfigured)
        #expect(manager.lastMirroredDate != nil)
        #expect(manager.lastMirrorError == "Mock Error")

        manager.clearDestination()

        #expect(manager.destinationName == nil)
        #expect(!manager.isCustomDestinationConfigured)
        #expect(manager.lastMirroredDate == nil)
        #expect(manager.lastMirrorError == nil)
    }

    @Test func saveDestinationStoresBookmarkAndName() throws {
        let (manager, defaults, suiteName) = makeManager()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("my-fav-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        try manager.saveDestination(from: tempFolder)

        #expect(manager.isCustomDestinationConfigured)
        #expect(manager.destinationName?.hasPrefix("my-fav-backup") == true)
    }

    @Test func mirrorArchiveSafelySkipsWhenUnconfigured() async {
        let (manager, defaults, suiteName) = makeManager()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? Data("test".utf8).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        // Must not crash or fail when no custom destination is set
        await manager.mirrorArchive(from: tempFile, budgetId: "b1", filename: "test.zip")
        await manager.removeMirroredArchive(budgetId: "b1", filename: "test.zip")
    }

    @Test func mirrorAndRemoveArchiveWithValidDestinationNamespacedByBudgetId() async throws {
        let (manager, defaults, suiteName) = makeManager()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirror-dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        try manager.saveDestination(from: tempFolder)

        let sourceFile = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID().uuidString).zip")
        try Data("mock archive content".utf8).write(to: sourceFile)
        defer { try? FileManager.default.removeItem(at: sourceFile) }

        let budgetId = "test-budget-123"
        let filename = "2026-09-03_21-00-00.zip"
        await manager.mirrorArchive(from: sourceFile, budgetId: budgetId, filename: filename)

        let mirroredFile = tempFolder.appendingPathComponent("Actuali/\(budgetId)/\(filename)")
        #expect(FileManager.default.fileExists(atPath: mirroredFile.path))
        #expect(manager.lastMirroredDate != nil)
        #expect(manager.lastMirrorError == nil)

        await manager.removeMirroredArchive(budgetId: budgetId, filename: filename)
        #expect(!FileManager.default.fileExists(atPath: mirroredFile.path))
    }
}
