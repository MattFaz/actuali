import Foundation
import Testing
import GRDB
@testable import Actuali

@MainActor
struct PayeeLocationTests {
    private func makeDatabasePath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
    }

    /// Minimal legacy schema: payees exists, payee_locations does not.
    private func makeLegacyFixture(_ path: URL) throws {
        let queue = try DatabaseQueue(path: path.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE payees (id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, tombstone INTEGER DEFAULT 0);
                CREATE TABLE payee_mapping (id TEXT PRIMARY KEY, targetId TEXT)
                """)
        }
    }

    @Test func migrationCreatesPayeeLocationsTable() throws {
        let path = makeDatabasePath()
        try makeLegacyFixture(path)
        _ = try BudgetDatabase(path: path)

        let queue = try DatabaseQueue(path: path.path)
        try queue.read { db in
            #expect(try db.tableExists("payee_locations"))
            let cols = Set(try db.columns(in: "payee_locations").map(\.name))
            #expect(cols == ["id", "payee_id", "latitude", "longitude", "created_at", "tombstone"])
            let indexes = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'payee_locations'
                """)
            #expect(indexes.contains("idx_payee_locations_payee_id"))
            #expect(indexes.contains("idx_payee_locations_tombstone_payee_created"))
            #expect(indexes.contains("idx_payee_locations_geo_tombstone"))
            let applied = try Int64.fetchAll(db, sql: "SELECT id FROM __migrations__")
            #expect(applied.contains(1768872504000))
        }
    }

    @Test func migrationToleratesUpstreamMigratedFile() throws {
        let path = makeDatabasePath()
        try makeLegacyFixture(path)
        let queue = try DatabaseQueue(path: path.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE payee_locations (id TEXT PRIMARY KEY, payee_id TEXT, latitude REAL, longitude REAL, created_at INTEGER, tombstone INTEGER DEFAULT 0);
                CREATE TABLE __migrations__ (id INTEGER PRIMARY KEY);
                INSERT INTO __migrations__ (id) VALUES (1768872504000)
                """)
        }
        _ = try BudgetDatabase(path: path)  // must not throw
    }

    @Test func haversineMatchesKnownDistances() {
        // Sydney Opera House -> Sydney Harbour Bridge (south-east pylon):
        // Haversine with R = 6371e3 gives 650.42 m for these coordinates.
        let d = LocationUtils.calculateDistanceMeters(
            lat1: -33.8568, lon1: 151.2153, lat2: -33.8523, lon2: 151.2108)
        #expect(abs(d - 650.42) < 1)
        // One degree of latitude at the equator: R * pi / 180 = 111,194.93 m
        let degree = LocationUtils.calculateDistanceMeters(lat1: 0, lon1: 0, lat2: 1, lon2: 0)
        #expect(abs(degree - 111_194.93) < 1)
        // Identical points -> 0
        #expect(LocationUtils.calculateDistanceMeters(lat1: 10, lon1: 10, lat2: 10, lon2: 10) == 0)
    }

    @Test func nearbyPayeesRanksAndDedupes() async throws {
        let path = makeDatabasePath()
        try makeLegacyFixture(path)
        let database = try BudgetDatabase(path: path)

        try database.insertPayee(Payee(id: "p-near", name: "Near Cafe", transferAccountId: nil))
        try database.insertPayee(Payee(id: "p-far", name: "Far Cafe", transferAccountId: nil))
        try database.insertPayee(Payee(id: "p-dead", name: "Dead Cafe", transferAccountId: nil))

        // p-near has two locations; the closer one must win (dedupe per payee).
        try database.insertPayeeLocation(PayeeLocation(
            id: "l1", payeeId: "p-near", latitude: 0.0010, longitude: 0, createdAt: 1))  // ~111 m
        try database.insertPayeeLocation(PayeeLocation(
            id: "l2", payeeId: "p-near", latitude: 0.0030, longitude: 0, createdAt: 2))  // ~333 m
        try database.insertPayeeLocation(PayeeLocation(
            id: "l3", payeeId: "p-far", latitude: 0.0400, longitude: 0, createdAt: 3))   // ~4.4 km, outside 500 m
        try database.insertPayeeLocation(PayeeLocation(
            id: "l4", payeeId: "p-dead", latitude: 0.0001, longitude: 0, createdAt: 4, tombstone: true))

        let nearby = try await database.fetchNearbyPayees(latitude: 0, longitude: 0, maxDistanceMeters: 500)
        #expect(nearby.count == 1)
        #expect(nearby.first?.payee.id == "p-near")
        #expect(nearby.first?.location.id == "l1")
        let dist = try #require(nearby.first?.distanceMeters)
        #expect(abs(dist - 111) < 10)
    }

    @Test func fetchPayeeLocationsFiltersAndOrders() async throws {
        let path = makeDatabasePath()
        try makeLegacyFixture(path)
        let database = try BudgetDatabase(path: path)
        try database.insertPayee(Payee(id: "p1", name: "P1", transferAccountId: nil))
        try database.insertPayeeLocation(PayeeLocation(id: "a", payeeId: "p1", latitude: 1, longitude: 1, createdAt: 100))
        try database.insertPayeeLocation(PayeeLocation(id: "b", payeeId: "p1", latitude: 2, longitude: 2, createdAt: 200))
        try database.insertPayeeLocation(PayeeLocation(id: "c", payeeId: "p1", latitude: 3, longitude: 3, createdAt: 300, tombstone: true))

        let locations = try await database.fetchPayeeLocations(payeeId: "p1")
        #expect(locations.map(\.id) == ["b", "a"])  // created_at DESC, tombstones excluded
    }

    /// CRDT sync applies one message per column, so a payee_locations row can
    /// exist with only payee_id set. Both fetches must skip it, not crash on
    /// decoding NULL into a non-optional.
    @Test func fetchesSkipPartiallySyncedRows() async throws {
        let path = makeDatabasePath()
        try makeLegacyFixture(path)
        let database = try BudgetDatabase(path: path)
        try database.insertPayee(Payee(id: "p1", name: "P1", transferAccountId: nil))
        try database.insertPayeeLocation(PayeeLocation(id: "full", payeeId: "p1", latitude: 0, longitude: 0, createdAt: 100))

        let queue = try DatabaseQueue(path: path.path)
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO payee_locations (id, payee_id) VALUES (?, ?)",
                arguments: ["partial", "p1"])
        }

        let locations = try await database.fetchPayeeLocations(payeeId: "p1")
        #expect(locations.map(\.id) == ["full"])

        let nearby = try await database.fetchNearbyPayees(latitude: 0, longitude: 0, maxDistanceMeters: 500)
        #expect(nearby.map(\.location.id) == ["full"])
    }

    @Test func formatDistanceMatchesUpstream() {
        #expect(LocationUtils.formatDistance(meters: 100) == "328ft | 100m")
    }

    @Test func payeeLocationGeneratesCRDTMessages() async throws {
        let generator = MessageGenerator(clock: HybridLogicalClock(node: "test-node"))
        let location = PayeeLocation(
            id: "loc-1", payeeId: "p1", latitude: -33.85, longitude: 151.21,
            createdAt: 1_751_760_000_000)
        let messages = try await generator.messagesForInsert(location)
        #expect(messages.count == 5)
        #expect(Set(messages.map(\.dataset)) == ["payee_locations"])
        #expect(Set(messages.map(\.row)) == ["loc-1"])
        #expect(Set(messages.map(\.column))
            == ["payee_id", "latitude", "longitude", "created_at", "tombstone"])

        // Pin the wire values — coordinates must keep full Double precision.
        let byColumn = Dictionary(uniqueKeysWithValues: messages.map { ($0.column, $0.value) })
        #expect(byColumn["latitude"] == "N:-33.85")
        #expect(byColumn["longitude"] == "N:151.21")
        #expect(byColumn["created_at"] == "N:1751760000000")
        #expect(byColumn["payee_id"] == "S:p1")
        #expect(byColumn["tombstone"] == "N:0")
    }

    @Test func crdtValueRoundTripsDoublesWithoutTruncation() {
        // Fractional doubles keep full precision on the wire.
        #expect(CRDTValue.serialize(-33.85) == "N:-33.85")
        #expect(CRDTValue.deserialize("N:-33.85") == (-33.85).databaseValue)
        #expect(CRDTValue.serialize(151.21) == "N:151.21")
        #expect(CRDTValue.deserialize("N:151.21") == 151.21.databaseValue)
        // Ints keep the bare "N:5" form — no ".0" suffix.
        #expect(CRDTValue.serialize(5) == "N:5")
        #expect(CRDTValue.serialize(Int64(5)) == "N:5")
        #expect(CRDTValue.deserialize("N:5") == Int64(5).databaseValue)
    }

    private final class FakePositionSource: PositionSource, @unchecked Sendable {
        var callCount = 0
        var status: LocationAuthStatus = .granted
        func requestPermission() async -> LocationAuthStatus { status }
        func authorizationStatus() -> LocationAuthStatus { status }
        func fetchPosition() async throws -> Coordinates {
            callCount += 1
            return Coordinates(latitude: 1, longitude: 2)
        }
    }

    @Test func locationProviderCachesPositionFor60Seconds() async throws {
        let fake = FakePositionSource()
        let provider = LocationProvider(source: fake)
        _ = try await provider.currentPosition()
        _ = try await provider.currentPosition()
        #expect(fake.callCount == 1)  // second call served from cache
    }

    @Test func locationProviderReturnsNilPositionWhenDenied() async {
        let fake = FakePositionSource()
        fake.status = .denied
        let provider = LocationProvider(source: fake)
        let position = try? await provider.currentPosition()
        #expect(position == nil)
    }

    @Test(arguments: [
        ("26.4.0", true), ("26.4.1", true), ("26.5.0", true), ("27.0.0", true),
        ("26.3.9", false), ("25.12.0", false), ("26.4", true),
        ("v26.4.0", false), ("", false), ("garbage", false),
    ])
    func serverVersionGate(version: String, expected: Bool) {
        #expect(ServerVersion.supportsPayeeLocations(version) == expected)
    }

    @Test func serverVersionGateTreatsNilAsUnsupported() {
        #expect(ServerVersion.supportsPayeeLocations(nil) == false)
    }

    @Test func shouldRecordLocationDedupesWithin500m() {
        let here = Coordinates(latitude: 0, longitude: 0)
        let nearLoc = PayeeLocation(id: "a", payeeId: "p", latitude: 0.001, longitude: 0, createdAt: 1)   // ~111 m
        let farLoc = PayeeLocation(id: "b", payeeId: "p", latitude: 0.04, longitude: 0, createdAt: 2)     // ~4.4 km

        #expect(BudgetStore.shouldRecordLocation(at: here, existing: []) == true)
        #expect(BudgetStore.shouldRecordLocation(at: here, existing: [farLoc]) == true)
        #expect(BudgetStore.shouldRecordLocation(at: here, existing: [nearLoc, farLoc]) == false)
    }
}
