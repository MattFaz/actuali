import Foundation
import GRDB
import Synchronization
import Testing
@testable import Actuali

/// Issue #99: on a fresh install the downloaded budget file has no decodable
/// messages_clock, so lastSyncedTimestamp is nil and fullSync used to fabricate
/// a 24-hour `since` window — silently skipping every server message between
/// the file snapshot's high-water mark and yesterday, then adopting the
/// server's merkle so the gap never healed. The first sync must instead ask
/// for everything after the snapshot's newest CRDT message.
struct SyncClientFreshInstallSinceTests {
    /// Mirrors a freshly downloaded budget file: messages_crdt populated up to
    /// the snapshot time, no messages_clock table at all.
    private func makeDatabase(snapshotTimestamps: [String]) async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase([TestSchema.messagesCrdt] + snapshotTimestamps.map {
            "INSERT INTO messages_crdt (timestamp, dataset, row, column, value) VALUES ('\($0)', 'transactions', 'row-1', 'amount', 'N:1')"
        })
    }

    /// The `since` of every body POSTed to /sync/sync.
    private final class CapturedSince: Sendable {
        let values = Mutex<[String]>([])
    }

    /// Answers /sync/sync with a canned, valid response (no messages, empty
    /// merkle) and records each request's `since`, so fullSync's request can
    /// be inspected without a server.
    private func makeSyncClient(
        database: BudgetDatabase, recording captured: CapturedSince
    ) async throws -> SyncClient {
        let session = StubTransport.session { request in
            let since = try SyncRequest(serializedData: request.bodyData).since
            captured.values.withLock { $0.append(since) }
            var response = SyncResponse()
            response.merkle = #"{"hash":0}"#
            return try StubTransport.Response(
                contentType: "application/actual-sync", body: response.serializedData()
            )
        }
        let serverClient = ActualServerClient(session: session)
        try await serverClient.configure(serverURL: "https://budget.example.com")
        await serverClient.setToken("test-token")

        let syncClient = SyncClient(serverClient: serverClient, nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        return syncClient
    }

    @Test func firstSyncAsksForEverythingAfterTheSnapshotHighWaterMark() async throws {
        // A snapshot whose newest message is weeks old — like the reporter's
        // 3-week-old server file.
        let snapshotHighWaterMark = "2026-07-22T10:00:00.000Z-0000-a1b2c3d4e5f60718"
        let (database, path) = try await makeDatabase(snapshotTimestamps: [
            "2026-07-01T09:00:00.000Z-0000-a1b2c3d4e5f60718",
            snapshotHighWaterMark,
        ])
        defer { cleanup(path) }
        let captured = CapturedSince()
        let syncClient = try await makeSyncClient(database: database, recording: captured)

        await syncClient.syncNow()

        // Everything after the snapshot lives only on the server, no matter
        // how old — a fabricated recent window drops it permanently.
        let since = try #require(captured.values.withLock { $0.first })
        #expect(since == snapshotHighWaterMark)
    }

    @Test func firstSyncOfAnEmptyBudgetAsksForTheFullServerLog() async throws {
        let (database, path) = try await makeDatabase(snapshotTimestamps: [])
        defer { cleanup(path) }
        let captured = CapturedSince()
        let syncClient = try await makeSyncClient(database: database, recording: captured)

        await syncClient.syncNow()

        // With no local floor at all, the only safe request is the server's
        // entire message log (which only spans back to the file's last
        // upload/reset).
        let since = try #require(captured.values.withLock { $0.first })
        #expect(since == HLCTimestamp.zero.toString())
    }
}
