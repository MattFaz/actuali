import Combine
import Foundation
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreSyncStatusTests {
    @Test func automaticSyncDoesNotInvalidateBudgetStore() async throws {
        let (database, url) = try await makeTestDatabase(TestSchema.core)
        defer { cleanup(url) }
        let session = StubTransport.session { _ in
            var response = SyncResponse()
            response.merkle = #"{"hash":0}"#
            return try StubTransport.Response(
                contentType: "application/actual-sync", body: response.serializedData()
            )
        }
        let serverClient = ActualServerClient(session: session)
        try await serverClient.configure(serverURL: "https://budget.example.com")
        await serverClient.setToken("test-token")
        let client = SyncClient(serverClient: serverClient, nodeId: "89e0e8e90b203f9e")
        try await client.configure(database: database, fileId: "test-file", groupId: "test-group")
        let store = BudgetStore.previewInstance()
        store.configureForTesting(database: database, syncClient: client)

        var storePublishes = 0
        var previousStates: [SyncState] = []
        let storeSubscription = store.objectWillChange.sink { storePublishes += 1 }
        // objectWillChange reports the value before each transition.
        let statusSubscription = store.syncStatus.objectWillChange.sink {
            previousStates.append(store.syncStatus.state)
        }
        defer {
            storeSubscription.cancel()
            statusSubscription.cancel()
        }

        #expect(await client.automaticSync())
        // The store receives the client's transitions through the main queue.
        for _ in 0..<200 {
            if previousStates.count >= 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(previousStates == [.idle, .syncing])
        #expect(store.syncStatus.state == .idle)
        #expect(storePublishes == 0)
        // Automatic pushes have never stamped the last-attempt timestamp.
        #expect(store.syncStatus.lastSyncTime == nil)
    }

    @Test func statusWritesAreIsolatedDeduplicatedAndBatched() {
        let store = BudgetStore.previewInstance()
        let started = Date(timeIntervalSince1970: 100)
        let finished = Date(timeIntervalSince1970: 200)
        var storePublishes = 0
        var statusPublishes = 0
        let storeSubscription = store.objectWillChange.sink { storePublishes += 1 }
        let statusSubscription = store.syncStatus.objectWillChange.sink { statusPublishes += 1 }
        defer {
            storeSubscription.cancel()
            statusSubscription.cancel()
        }

        store.syncState = .idle
        store.lastSyncTime = nil
        #expect(statusPublishes == 0)

        store.syncState = .syncing
        store.syncState = .syncing
        #expect(store.syncStatus.state == .syncing)
        #expect(statusPublishes == 1)

        store.lastSyncTime = started
        store.lastSyncTime = started
        #expect(store.syncStatus.lastSyncTime == started)
        #expect(statusPublishes == 2)

        store.syncStatus.update(state: .idle, lastSyncTime: finished)
        #expect(store.syncState == .idle)
        #expect(store.lastSyncTime == finished)
        #expect(statusPublishes == 3)

        store.syncState = .offline
        store.syncState = .error("Connection failed")
        store.syncState = .error("Connection failed")
        #expect(store.syncStatus.state == .error("Connection failed"))
        #expect(store.lastSyncTime == finished)
        #expect(statusPublishes == 5)

        store.syncStatus.update(state: .idle, lastSyncTime: nil)
        #expect(store.syncState == .idle)
        #expect(store.lastSyncTime == nil)
        #expect(statusPublishes == 6)
        #expect(storePublishes == 0)
    }
}
