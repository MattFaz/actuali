import Foundation
import Testing
@testable import Actuali

/// Pull-to-refresh runs `BudgetStore.sync()` inside SwiftUI's `.refreshable`
/// task, which the system may cancel on further scroll interaction. A
/// cancelled caller must not abort the sync pipeline mid-flight or surface
/// `Swift.CancellationError` to the user — the Reports tab showed a
/// "Something Went Wrong" alert and went blank when that happened.
@MainActor
struct BudgetStoreSyncCancellationTests {
    /// The server client is unconfigured, so the network leg of the sync
    /// fails fast and locally; the data refresh afterwards runs against the
    /// fixture for real.
    @Test func syncSurvivesCallerCancellationWithoutPublishingError() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core + [
            "INSERT INTO accounts (id, name, type, sort_order) VALUES ('acct-1', 'Checking', 'checking', 1.0)",
        ])
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)

        // Cancel before the task body has a chance to run (both are
        // main-actor bound and there is no suspension point in between), so
        // the whole pipeline executes under a cancelled task — exactly what
        // .refreshable does when the gesture cancels the refresh.
        let task = Task { await store.sync() }
        task.cancel()
        await task.value

        #expect(store.error == nil)
        #expect(store.syncStatus.lastSyncTime != nil)
        // The post-sync data refresh must have completed, not been aborted.
        #expect(store.accounts.map(\.name) == ["Checking"])
    }
}
