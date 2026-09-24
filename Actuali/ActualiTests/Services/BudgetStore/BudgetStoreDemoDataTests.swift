import Foundation
import Testing
@testable import Actuali

/// Tests for loadDemoData and budget switching cleanup.
@Suite(.serialized)
@MainActor
struct BudgetStoreDemoDataTests {
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
        let realDir = manager.budgetDirectory(for: "real-budget")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        _ = try BudgetDatabase(path: manager.databasePath(for: "real-budget"))

        await store.loadLocalBudget("real-budget")

        #expect(!PendingImportStore.shared.imports.contains { $0.originBudgetId == DemoDataSeeder.budgetId })
    }
}
