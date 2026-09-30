import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreBackgroundSyncTests {
    @Test func reportsNoBudgetWhenNothingConfigured() async {
        let store = BudgetStore.previewInstance()

        let synced = await store.syncInBackground()

        #expect(synced == false)
    }

    /// The server client is unconfigured, so the sync attempt fails fast and
    /// locally — syncInBackground still reports true because a loaded budget
    /// attempted a sync (the flag means "budget present", not "server reachable").
    @Test func reportsSyncAttemptedWhenBudgetConfigured() async throws {
        // messages_crdt alone is enough for SyncClient.configure to load its clock.
        let (database, url) = try await makeTestDatabase(TestSchema.messagesCrdt)
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)

        let synced = await store.syncInBackground()

        #expect(synced == true)
    }
}
