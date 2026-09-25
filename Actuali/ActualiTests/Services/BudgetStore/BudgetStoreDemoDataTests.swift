import Foundation
import GRDB
import Testing
@testable import Actuali

/// Tests for loadDemoData and budget switching cleanup.
@Suite(.serialized)
@MainActor
struct BudgetStoreDemoDataTests {
    private func seedBudget(id: String, in manager: BudgetFileManager) throws {
        let dir = manager.budgetDirectory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: manager.databasePath(for: id).path)
        try queue.write { db in
            try db.execute(sql: BudgetStoreInitialSyncTests.upstreamSchema)
        }
        try JSONEncoder().encode(BudgetMetadata(
            id: id, budgetName: "Real Budget", cloudFileId: nil, groupId: nil,
            resetClock: nil, lastUploaded: nil, encryptKeyId: nil
        )).write(to: manager.metadataPath(for: id))
    }

    @Test func loadDemoDataSeedsPendingImportAndSwitchingBudgetsCleansIt() async throws {
        let saved = UserDefaults.standard.string(forKey: "currentBudgetId")
        defer {
            UserDefaults.standard.set(saved, forKey: "currentBudgetId")
            try? PendingImportStore.shared.removeImports(originBudgetId: DemoDataSeeder.budgetId)
        }

        let store = BudgetStore.previewInstance()
        await store.loadDemoData()

        #expect(PendingImportStore.shared.imports.contains { $0.originBudgetId == DemoDataSeeder.budgetId })

        // Loading a non-demo budget cleans up demo imports
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("demo-cleanup-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = BudgetFileManager(rootDirectoryForTesting: root)
        store.setFileManagerForTesting(manager)
        try seedBudget(id: "real-budget", in: manager)

        await store.loadLocalBudget("real-budget")

        #expect(!PendingImportStore.shared.imports.contains { $0.originBudgetId == DemoDataSeeder.budgetId })
    }
}
