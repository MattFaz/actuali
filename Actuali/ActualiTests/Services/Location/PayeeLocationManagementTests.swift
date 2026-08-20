import Foundation
import GRDB
import Testing
@testable import Actuali

/// Backing queries and writes for the Payee Locations management screen
/// (GH #147): list every payee that has recorded locations, and clear them
/// one at a time or all at once.
struct PayeeLocationManagementTests {

    private func makeDatabasePath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
    }

    /// Minimal legacy schema: payees exists, payee_locations comes from our
    /// migration. messages_crdt normally arrives with the downloaded budget
    /// file, so create it with the upstream schema.
    private func makeFixture(_ path: URL) throws {
        let queue = try DatabaseQueue(path: path.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE payees (id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, tombstone INTEGER DEFAULT 0);
                CREATE TABLE payee_mapping (id TEXT PRIMARY KEY, targetId TEXT);
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
    }

    private func makeSyncClient(database: BudgetDatabase) async throws -> SyncClient {
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        return syncClient
    }

    // MARK: - Listing

    /// The screen's top level: one row per payee that still has at least one
    /// location, name-ordered, with a live count.
    @Test func fetchPayeesWithLocationsCountsAndOrders() async throws {
        let path = makeDatabasePath()
        try makeFixture(path)
        defer { try? FileManager.default.removeItem(at: path) }
        let database = try BudgetDatabase(path: path)

        try database.insertPayee(Payee(id: "p-b", name: "Bakery", transferAccountId: nil))
        try database.insertPayee(Payee(id: "p-a", name: "Apple Store", transferAccountId: nil))
        try database.insertPayee(Payee(id: "p-none", name: "No Locations", transferAccountId: nil))

        try database.insertPayeeLocation(PayeeLocation(
            id: "l1", payeeId: "p-b", latitude: 1, longitude: 1, createdAt: 100))
        try database.insertPayeeLocation(PayeeLocation(
            id: "l2", payeeId: "p-b", latitude: 2, longitude: 2, createdAt: 200))
        try database.insertPayeeLocation(PayeeLocation(
            id: "l3", payeeId: "p-a", latitude: 3, longitude: 3, createdAt: 300))

        let summaries = try await database.fetchPayeesWithLocations()

        // Name-ordered, payees without locations omitted.
        #expect(summaries.map(\.payee.id) == ["p-a", "p-b"])
        #expect(summaries.map(\.locationCount) == [1, 2])
        #expect(summaries.first?.payee.name == "Apple Store")
    }

    /// Tombstoned locations don't count, and a payee whose every location is
    /// tombstoned drops off the list entirely — otherwise clearing a payee
    /// would leave an empty row behind.
    @Test func fetchPayeesWithLocationsExcludesTombstones() async throws {
        let path = makeDatabasePath()
        try makeFixture(path)
        defer { try? FileManager.default.removeItem(at: path) }
        let database = try BudgetDatabase(path: path)

        try database.insertPayee(Payee(id: "p-live", name: "Live", transferAccountId: nil))
        try database.insertPayee(Payee(id: "p-cleared", name: "Cleared", transferAccountId: nil))
        try database.insertPayee(
            Payee(id: "p-dead", name: "Deleted Payee", transferAccountId: nil, tombstone: true))

        try database.insertPayeeLocation(PayeeLocation(
            id: "keep", payeeId: "p-live", latitude: 1, longitude: 1, createdAt: 100))
        try database.insertPayeeLocation(PayeeLocation(
            id: "gone", payeeId: "p-live", latitude: 2, longitude: 2, createdAt: 200, tombstone: true))
        try database.insertPayeeLocation(PayeeLocation(
            id: "all-gone", payeeId: "p-cleared", latitude: 3, longitude: 3, createdAt: 300, tombstone: true))
        try database.insertPayeeLocation(PayeeLocation(
            id: "orphan", payeeId: "p-dead", latitude: 4, longitude: 4, createdAt: 400))

        let summaries = try await database.fetchPayeesWithLocations()

        #expect(summaries.map(\.payee.id) == ["p-live"])
        #expect(summaries.first?.locationCount == 1)
    }

    /// CRDT sync applies one message per column, so a row can exist with only
    /// payee_id set. It must not be counted (the detail fetch already skips it,
    /// so counting it would show "1 location" over an empty list).
    @Test func fetchPayeesWithLocationsSkipsPartiallySyncedRows() async throws {
        let path = makeDatabasePath()
        try makeFixture(path)
        defer { try? FileManager.default.removeItem(at: path) }
        let database = try BudgetDatabase(path: path)

        try database.insertPayee(Payee(id: "p1", name: "P1", transferAccountId: nil))
        let queue = try DatabaseQueue(path: path.path)
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO payee_locations (id, payee_id) VALUES (?, ?)",
                arguments: ["partial", "p1"])
        }

        #expect(try await database.fetchPayeesWithLocations().isEmpty)

        try database.insertPayeeLocation(PayeeLocation(
            id: "full", payeeId: "p1", latitude: 1, longitude: 1, createdAt: 100))
        let summaries = try await database.fetchPayeesWithLocations()
        #expect(summaries.map(\.locationCount) == [1])
    }

    // MARK: - Clearing all

    /// "Clear All Locations" tombstones every row for the payee and replicates
    /// one tombstone message each, in a single sync — not one sync per row.
    @Test func deletePayeeLocationsTombstonesAllAndEmitsOneMessageEach() async throws {
        let path = makeDatabasePath()
        try makeFixture(path)
        defer { try? FileManager.default.removeItem(at: path) }
        let database = try BudgetDatabase(path: path)

        try database.insertPayee(Payee(id: "p1", name: "P1", transferAccountId: nil))
        try database.insertPayee(Payee(id: "p2", name: "P2", transferAccountId: nil))
        let doomed = [
            PayeeLocation(id: "a", payeeId: "p1", latitude: 1, longitude: 1, createdAt: 100),
            PayeeLocation(id: "b", payeeId: "p1", latitude: 2, longitude: 2, createdAt: 200)
        ]
        for location in doomed { try database.insertPayeeLocation(location) }
        try database.insertPayeeLocation(PayeeLocation(
            id: "other", payeeId: "p2", latitude: 3, longitude: 3, createdAt: 300))

        let syncClient = try await makeSyncClient(database: database)
        try await syncClient.deletePayeeLocations(doomed)

        #expect(try await database.fetchPayeeLocations(payeeId: "p1").isEmpty)
        // Untouched payees keep their locations.
        #expect(try await database.fetchPayeeLocations(payeeId: "p2").map(\.id) == ["other"])

        let queue = try DatabaseQueue(path: path.path)
        let messages = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM messages_crdt ORDER BY timestamp")
                .map { (row: $0["row"] as String,
                        dataset: $0["dataset"] as String,
                        column: $0["column"] as String,
                        value: $0["value"] as String) }
        }
        #expect(messages.count == 2)
        #expect(Set(messages.map(\.row)) == ["a", "b"])
        #expect(Set(messages.map(\.dataset)) == ["payee_locations"])
        #expect(Set(messages.map(\.column)) == ["tombstone"])
        #expect(Set(messages.map(\.value)) == ["N:1"])
    }

    /// Nothing to clear is a no-op, not an error and not a spurious sync.
    @Test func deletePayeeLocationsWithEmptyListIsANoOp() async throws {
        let path = makeDatabasePath()
        try makeFixture(path)
        defer { try? FileManager.default.removeItem(at: path) }
        let database = try BudgetDatabase(path: path)
        let syncClient = try await makeSyncClient(database: database)

        try await syncClient.deletePayeeLocations([])

        let queue = try DatabaseQueue(path: path.path)
        let count = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt")
        }
        #expect(count == 0)
    }

    @Test func deletePayeeLocationsThrowsWhenNotConfigured() async throws {
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        let location = PayeeLocation(id: "a", payeeId: "p1", latitude: 0, longitude: 0, createdAt: 1)
        await #expect(throws: SyncError.self) {
            try await syncClient.deletePayeeLocations([location])
        }
    }

    // MARK: - Store gating

    /// Every write path is gated on the server supporting payee_locations
    /// (>= 26.4.0), the same guard `deletePayeeLocation` already applies —
    /// otherwise the screen would appear to clear rows that never replicate.
    @MainActor
    @Test func storeRefusesBulkDeleteWhenWritesDisabled() async {
        let store = BudgetStore.previewInstance()
        let location = PayeeLocation(id: "a", payeeId: "p1", latitude: 0, longitude: 0, createdAt: 1)
        #expect(store.payeeLocationWritesEnabled == false)
        #expect(await store.deletePayeeLocations([location]) == false)
    }

    /// With no database wired up the listing degrades to empty rather than
    /// throwing into the view.
    @MainActor
    @Test func storeReturnsNoSummariesWithoutDatabase() async {
        let store = BudgetStore.previewInstance()
        #expect(await store.fetchPayeesWithLocations().isEmpty)
    }
}
