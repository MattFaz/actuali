import Foundation
import Testing
@testable import Actuali

/// Leaving the demo removes its sample pending import, and only that one.
/// Goes through `loadLocalBudget` on an isolated store rather than
/// `loadDemoData`, which rewrites the shared demo directory that
/// `DemoDataSeederTests` reads in parallel.
@MainActor
struct BudgetStoreDemoDataTests {
    @Test func loadingAnotherBudgetRemovesOnlyTheDemoSample() async throws {
        let pending = PendingImportStore.shared
        let queuedInDemo = PendingImport(originBudgetId: DemoDataSeeder.budgetId, amount: 12)
        defer {
            try? DemoDataSeeder.removeSamplePendingImport()
            try? pending.remove(id: queuedInDemo.id)
        }
        try DemoDataSeeder.seedPendingImports()
        try pending.add(queuedInDemo)

        let (store, manager, root) = makeFileBackedStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBudget(id: "real-budget", in: manager)

        await store.loadLocalBudget("real-budget")

        let ids = pending.imports.map(\.id)
        #expect(!ids.contains(DemoDataSeeder.samplePendingImportId))
        // A real shortcut import queued while the demo was open survives.
        #expect(ids.contains(queuedInDemo.id))
    }
}
