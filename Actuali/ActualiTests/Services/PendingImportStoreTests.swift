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
        store.add(item)
        #expect(store.count == 1)
        #expect(store.imports.first?.payee == "Test")

        store.remove(id: item.id)
        #expect(store.count == 0)
    }

    @Test @MainActor func removeAll() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        store.add(PendingImport(amount: 1, rawText: "a"))
        store.add(PendingImport(amount: 2, rawText: "b"))
        #expect(store.count == 2)

        store.removeAll()
        #expect(store.count == 0)
    }

    @Test @MainActor func persistsAcrossInstances() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_pending_imports_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store1 = PendingImportStore(fileURL: url)
        store1.add(PendingImport(amount: 42, payee: "Persisted", rawText: "msg"))
        #expect(store1.count == 1)

        let store2 = PendingImportStore(fileURL: url)
        #expect(store2.count == 1)
        #expect(store2.imports.first?.payee == "Persisted")
    }
}
