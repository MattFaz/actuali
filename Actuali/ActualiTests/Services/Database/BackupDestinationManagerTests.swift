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

    @Test func defaultStateHasNoCustomDestination() async {
        let (manager, defaults, suiteName) = makeManager()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let name = await manager.destinationName
        let isConfigured = await manager.isCustomDestinationConfigured
        let lastDate = await manager.lastMirroredDate
        let lastError = await manager.lastMirrorError

        #expect(name == nil)
        #expect(!isConfigured)
        #expect(lastDate == nil)
        #expect(lastError == nil)
    }

    @Test func clearDestinationRemovesKeys() async {
        let (manager, defaults, suiteName) = makeManager()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("FakeBookmark".data(using: .utf8), forKey: BackupDestinationManager.bookmarkKey)
        defaults.set("my-fav-backup", forKey: BackupDestinationManager.nameKey)
        defaults.set(Date(), forKey: BackupDestinationManager.lastMirroredDateKey)
        defaults.set("Mock Error", forKey: BackupDestinationManager.lastMirrorErrorKey)

        let nameBefore = await manager.destinationName
        let isConfiguredBefore = await manager.isCustomDestinationConfigured
        let lastDateBefore = await manager.lastMirroredDate
        let lastErrorBefore = await manager.lastMirrorError

        #expect(nameBefore == "my-fav-backup")
        #expect(isConfiguredBefore)
        #expect(lastDateBefore != nil)
        #expect(lastErrorBefore == "Mock Error")

        await manager.clearDestination()

        let nameAfter = await manager.destinationName
        let isConfiguredAfter = await manager.isCustomDestinationConfigured
        let lastDateAfter = await manager.lastMirroredDate
        let lastErrorAfter = await manager.lastMirrorError

        #expect(nameAfter == nil)
        #expect(!isConfiguredAfter)
        #expect(lastDateAfter == nil)
        #expect(lastErrorAfter == nil)
    }

    @Test func saveDestinationStoresBookmarkAndName() async throws {
        let (manager, defaults, suiteName) = makeManager()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("my-fav-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        try await manager.saveDestination(from: tempFolder)

        let isConfigured = await manager.isCustomDestinationConfigured
        let name = await manager.destinationName

        #expect(isConfigured)
        #expect(name?.hasPrefix("my-fav-backup") == true)
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

        try await manager.saveDestination(from: tempFolder)

        let sourceFile = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID().uuidString).zip")
        try Data("mock archive content".utf8).write(to: sourceFile)
        defer { try? FileManager.default.removeItem(at: sourceFile) }

        let budgetId = "test-budget-123"
        let filename = "2026-09-03_21-00-00.zip"
        await manager.mirrorArchive(from: sourceFile, budgetId: budgetId, filename: filename)

        let mirroredFile = tempFolder.appendingPathComponent("Actuali/\(budgetId)/\(filename)")
        #expect(FileManager.default.fileExists(atPath: mirroredFile.path))

        let lastDate = await manager.lastMirroredDate
        let lastError = await manager.lastMirrorError
        #expect(lastDate != nil)
        #expect(lastError == nil)

        await manager.removeMirroredArchive(budgetId: budgetId, filename: filename)
        #expect(!FileManager.default.fileExists(atPath: mirroredFile.path))
    }
}
