import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreBackgroundSyncTests {

    /// Minimal upstream schema so SyncClient.configure can load its clock
    /// (matches BudgetStoreSaveTransactionTests).
    private func makeDatabase() throws -> BudgetDatabase {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE messages_crdt (
                    id INTEGER PRIMARY KEY,
                    timestamp TEXT NOT NULL UNIQUE,
                    dataset TEXT NOT NULL,
                    row TEXT NOT NULL,
                    column TEXT NOT NULL,
                    value BLOB NOT NULL
                )
                """)
        }
        return try BudgetDatabase(path: tempURL)
    }

    @Test func reportsNoBudgetWhenNothingConfigured() async {
        let store = BudgetStore.previewInstance()

        let synced = await store.syncInBackground()

        #expect(synced == false)
    }

    /// The server client is unconfigured, so the sync attempt fails fast and
    /// locally — syncInBackground still reports true because a loaded budget
    /// attempted a sync (the flag means "budget present", not "server reachable").
    @Test func reportsSyncAttemptedWhenBudgetConfigured() async throws {
        let database = try makeDatabase()
        let store = BudgetStore.previewInstance()
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        store.configureForTesting(database: database, syncClient: syncClient)

        let synced = await store.syncInBackground()

        #expect(synced == true)
    }
}
