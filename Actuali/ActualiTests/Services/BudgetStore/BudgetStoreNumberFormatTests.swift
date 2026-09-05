import Foundation
import GRDB
import Testing
@testable import Actuali

/// Number formatting is a synced budget preference, so BudgetStore must load
/// it from the budget database and keep a user's in-flight selection from
/// being overwritten by a stale refresh.
@MainActor
struct BudgetStoreNumberFormatTests {
    private func makeStore() throws -> (BudgetStore, BudgetFileManager, String, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("number-format-tests-\(UUID().uuidString)", isDirectory: true)
        let manager = BudgetFileManager(rootDirectoryForTesting: root)
        let store = BudgetStore.previewInstance()
        store.setFileManagerForTesting(manager)
        return (store, manager, "budget-\(UUID().uuidString)", root)
    }

    private func seedBudget(
        id: String,
        numberFormat: String? = nil,
        in manager: BudgetFileManager
    ) throws {
        let dir = manager.budgetDirectory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbQueue = try DatabaseQueue(path: manager.databasePath(for: id).path)
        try dbQueue.write { db in
            try db.execute(sql: BudgetStoreInitialSyncTests.upstreamSchema)
            if let numberFormat {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO preferences (id, value) VALUES ('numberFormat', ?)",
                    arguments: [numberFormat]
                )
            }
        }
        try JSONEncoder().encode(BudgetMetadata(
            id: id,
            budgetName: "Seed",
            cloudFileId: "cf-1",
            groupId: nil,
            resetClock: nil,
            lastUploaded: nil,
            encryptKeyId: nil
        )).write(to: manager.metadataPath(for: id))
    }

    @Test func loadAppliesStoredNumberFormat() async throws {
        let (store, manager, id, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBudget(id: id, numberFormat: ActualNumberFormat.dotComma.rawValue, in: manager)

        await store.loadLocalBudget(id)

        #expect(store.numberFormat == .dotComma)
    }

    @Test func loadDefaultsToCommaDotWhenPreferenceIsAbsent() async throws {
        let (store, manager, id, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBudget(id: id, in: manager)

        store.numberFormat = .indian
        await store.loadLocalBudget(id)

        #expect(store.numberFormat == .commaDot)
    }

    @Test func loadDefaultsToCommaDotForUnknownPreference() async throws {
        let (store, manager, id, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBudget(id: id, numberFormat: "not-a-real-format", in: manager)

        store.numberFormat = .indian
        await store.loadLocalBudget(id)

        #expect(store.numberFormat == .commaDot)
    }

    @Test func setNumberFormatUpdatesTheStoreImmediately() async {
        let store = BudgetStore.previewInstance()

        await store.setNumberFormat(.spaceComma)

        #expect(store.numberFormat == .spaceComma)
    }

    @Test func refreshAppliesFetchedNumberFormatWhenSelectionDidNotChange() async throws {
        let (store, manager, id, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBudget(id: id, numberFormat: .dotComma.rawValue, in: manager)

        store.currentBudgetId = id
        await store.loadLocalBudget(id)
        #expect(store.numberFormat == .dotComma)

        try await updateNumberFormat(.commaDotIn.rawValue, id: id, in: manager)
        store.numberFormat = .dotComma
        await store.resetSyncState()

        #expect(store.numberFormat == .commaDotIn)
    }

    @Test func refreshKeepsCurrentSelectionWhenPreferenceIsAbsent() async throws {
        let (store, manager, id, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBudget(id: id, in: manager)

        store.numberFormat = .apostropheDot
        store.currentBudgetId = id
        await store.loadLocalBudget(id)
        #expect(store.numberFormat == .commaDot)

        store.numberFormat = .apostropheDot
        await store.resetSyncState()

        #expect(store.numberFormat == .apostropheDot)
    }

    private func updateNumberFormat(
        _ value: String?, id: String, in manager: BudgetFileManager
    ) async throws {
        let dbQueue = try DatabaseQueue(path: manager.databasePath(for: id).path)
        try await dbQueue.write { db in
            if let value {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO preferences (id, value) VALUES ('numberFormat', ?)",
                    arguments: [value]
                )
            } else {
                try db.execute(sql: "DELETE FROM preferences WHERE id = 'numberFormat'")
            }
        }
    }
}
