import Foundation
import Testing
@testable import Actuali

struct PendingImportStoreTests {

    /// Creates a store backed by a temp file so tests don't pollute the real queue.
    @MainActor
    private func makeStore() -> (PendingImportStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_pending_imports_\(UUID().uuidString).json")
        let store = PendingImportStore(fileURL: url)
        return (store, url)
    }

    @Test @MainActor func addAndRemove() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let item = PendingImport(amount: 10.0, payee: "Test", rawText: "test")
        try! store.add(item)
        #expect(store.count == 1)
        #expect(store.imports.first?.payee == "Test")

        try! store.remove(id: item.id)
        #expect(store.count == 0)
    }

    @Test @MainActor func removeAll() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        try! store.add(PendingImport(amount: 1, rawText: "a"))
        try! store.add(PendingImport(amount: 2, rawText: "b"))
        #expect(store.count == 2)

        try! store.removeAll()
        #expect(store.count == 0)
    }

    @Test @MainActor func failedSaveDoesNotMutateTheQueue() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PendingImportStore(fileURL: directory)
        let item = PendingImport(amount: 1)

        #expect(throws: PendingImportStore.StoreError.self) {
            try store.add(item)
        }
        #expect(store.imports.isEmpty)
    }

    @Test @MainActor func persistsAcrossInstances() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_pending_imports_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store1 = PendingImportStore(fileURL: url)
        try! store1.add(PendingImport(originBudgetId: "budget-a", amount: 42, payee: "Persisted", rawText: "msg"))
        #expect(store1.count == 1)

        let store2 = PendingImportStore(fileURL: url)
        #expect(store2.count == 1)
        #expect(store2.imports.first?.payee == "Persisted")
        #expect(store2.imports.first?.originBudgetId == "budget-a")
    }

    @Test @MainActor func legacyRecordWithoutOriginBudgetIdStillDecodes() throws {
        let item = PendingImport(amount: 42, payee: "Legacy", rawText: "msg")
        var object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(item)) as! [String: Any]
        object.removeValue(forKey: "originBudgetId")
        let decoded = try JSONDecoder().decode(
            PendingImport.self,
            from: JSONSerialization.data(withJSONObject: object))

        #expect(decoded.id == item.id)
        #expect(decoded.originBudgetId == nil)
        #expect(decoded.payee == "Legacy")
    }

    @Test @MainActor func legacyRecordWithoutSourceCurrencyStillDecodesAsAmbiguous() throws {
        let item = PendingImport(amount: 42, payee: "Legacy", rawText: "msg")
        var object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(item)) as! [String: Any]
        object.removeValue(forKey: "sourceCurrencyCode")
        let decoded = try JSONDecoder().decode(
            PendingImport.self,
            from: JSONSerialization.data(withJSONObject: object))

        #expect(decoded.sourceCurrencyCode == nil)
    }

    @Test @MainActor func visibleImportsKeepAllBudgetsVisibleForReview() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let current = PendingImport(originBudgetId: "budget-a", amount: 1)
        let other = PendingImport(originBudgetId: "budget-b", amount: 2)
        let legacy = PendingImport(amount: 3)
        try! store.add(current)
        try! store.add(other)
        try! store.add(legacy)

        let visible = store.visibleImports()
        #expect(Set(visible.map(\.id)) == Set([current.id, other.id, legacy.id]))
    }

    @Test @MainActor func recoversMalformedFileAndPersistsSubsequentImport() throws {
        let directory = FileManager.default.temporaryDirectory
        let stem = "test_pending_imports_\(UUID().uuidString)"
        let url = directory.appendingPathComponent("\(stem).json")
        defer {
            try? FileManager.default.removeItem(at: url)
            for backup in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            where backup.lastPathComponent.hasPrefix(stem + ".corrupt-") {
                try? FileManager.default.removeItem(at: backup)
            }
        }

        try Data("{ malformed".utf8).write(to: url)
        let recovered = PendingImportStore(fileURL: url)

        #expect(recovered.imports.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(stem + ".corrupt-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: backups[0]) == Data("{ malformed".utf8))

        try! recovered.add(PendingImport(amount: 7, payee: "After Recovery", rawText: "msg"))
        let reloaded = PendingImportStore(fileURL: url)
        #expect(reloaded.imports.first?.payee == "After Recovery")
    }
}
