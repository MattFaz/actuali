import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetMonthSelectionTests {
    private func makeStore() -> (BudgetStore, BudgetFileManager, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("budget-month-tests-\(UUID().uuidString)", isDirectory: true)
        let manager = BudgetFileManager(rootDirectoryForTesting: root)
        let store = BudgetStore.previewInstance()
        store.setFileManagerForTesting(manager)
        return (store, manager, root)
    }

    private func seedBudget(_ id: String, in manager: BudgetFileManager) throws {
        try FileManager.default.createDirectory(
            at: manager.budgetDirectory(for: id), withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: manager.databasePath(for: id).path)
        try queue.write { try $0.execute(sql: BudgetStoreInitialSyncTests.upstreamSchema) }
        try JSONEncoder().encode(BudgetMetadata(
            id: id, budgetName: "Seed", cloudFileId: "cf-1", groupId: nil,
            resetClock: nil, lastUploaded: nil, encryptKeyId: nil
        )).write(to: manager.metadataPath(for: id))
    }

    @Test func loadRestoresPersistedMonthAndIgnoresAnotherBudgetsRequest() async throws {
        let (_, manager, root) = makeStore()
        let budgetId = "budget-\(UUID().uuidString)"
        let otherBudgetId = "budget-\(UUID().uuidString)"
        let key = "lastViewedBudgetMonth_\(budgetId)"
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removeObject(forKey: key)
        }
        try seedBudget(budgetId, in: manager)

        let persistenceStore = BudgetStore.previewInstance()
        persistenceStore.currentBudgetId = budgetId
        persistenceStore.lastViewedBudgetMonth = "2025-01"

        let store = BudgetStore.previewInstance()
        store.setFileManagerForTesting(manager)
        store.currentBudgetId = otherBudgetId
        await store.fetchBudgetMonth("2024-06")
        store.currentBudgetId = budgetId

        await store.loadLocalBudget(budgetId)

        #expect(store.error == nil)
        #expect(store.currentBudgetMonth?.month == "2025-01")
        #expect(store.widgetBudgetMonth?.month == BudgetView.currentMonthString())
    }

    @Test func loadPreservesMonthRequestedWhileLoading() async throws {
        let (store, manager, root) = makeStore()
        let budgetId = "budget-\(UUID().uuidString)"
        let key = "lastViewedBudgetMonth_\(budgetId)"
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removeObject(forKey: key)
        }
        try seedBudget(budgetId, in: manager)
        store.currentBudgetId = budgetId
        store.lastViewedBudgetMonth = "2025-01"
        store.budgetMonthsFetchedForTesting = {
            await store.fetchBudgetMonth("2025-02")
        }

        await store.loadLocalBudget(budgetId)

        store.budgetMonthsFetchedForTesting = nil
        #expect(store.error == nil)
        #expect(store.currentBudgetMonth?.month == "2025-02")
        #expect(store.widgetBudgetMonth?.month == BudgetView.currentMonthString())
    }
}
