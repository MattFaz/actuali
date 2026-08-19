import Foundation
import GRDB
import Testing
@testable import Actuali

/// Captures the body POSTed to /sync/sync and answers with a canned, valid
/// sync response (no messages, empty merkle), so fullSync's request can be
/// inspected without a server.
private final class SyncCaptureTransport: URLProtocol {
    nonisolated(unsafe) static var capturedBodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession delivers POST bodies to URLProtocol as a stream, not httpBody.
        if let stream = request.httpBodyStream {
            stream.open()
            var body = Data()
            let bufferSize = 16 * 1024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                guard read > 0 else { break }
                body.append(buffer, count: read)
            }
            stream.close()
            Self.capturedBodies.append(body)
        } else {
            Self.capturedBodies.append(request.httpBody ?? Data())
        }

        var response = SyncResponse()
        response.merkle = #"{"hash":0}"#
        let data = (try? response.serializedData()) ?? Data()

        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/actual-sync"]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Issue #99: on a fresh install the downloaded budget file has no decodable
/// messages_clock, so lastSyncedTimestamp is nil and fullSync used to fabricate
/// a 24-hour `since` window — silently skipping every server message between
/// the file snapshot's high-water mark and yesterday, then adopting the
/// server's merkle so the gap never healed. The first sync must instead ask
/// for everything after the snapshot's newest CRDT message.
@Suite(.serialized)
struct SyncClientFreshInstallSinceTests {

    /// Mirrors a freshly downloaded budget file: messages_crdt populated up to
    /// the snapshot time, no messages_clock table at all.
    private func makeDatabase(snapshotTimestamps: [String]) throws -> (BudgetDatabase, URL) {
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
            for timestamp in snapshotTimestamps {
                try db.execute(
                    sql: "INSERT INTO messages_crdt (timestamp, dataset, row, column, value) VALUES (?, 'transactions', 'row-1', 'amount', 'N:1')",
                    arguments: [timestamp]
                )
            }
        }
        return (try BudgetDatabase(path: tempURL), tempURL)
    }

    private func makeSyncClient(database: BudgetDatabase) async throws -> SyncClient {
        SyncCaptureTransport.capturedBodies = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SyncCaptureTransport.self]
        let serverClient = ActualServerClient(session: URLSession(configuration: config))
        try await serverClient.configure(serverURL: "https://budget.example.com")
        await serverClient.setToken("test-token")

        let syncClient = SyncClient(serverClient: serverClient, nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        return syncClient
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func capturedSince() throws -> String {
        let body = try #require(SyncCaptureTransport.capturedBodies.first)
        return try SyncRequest(serializedData: body).since
    }

    @Test func firstSyncAsksForEverythingAfterTheSnapshotHighWaterMark() async throws {
        // A snapshot whose newest message is weeks old — like the reporter's
        // 3-week-old server file.
        let snapshotHighWaterMark = "2026-07-22T10:00:00.000Z-0000-a1b2c3d4e5f60718"
        let (database, path) = try makeDatabase(snapshotTimestamps: [
            "2026-07-01T09:00:00.000Z-0000-a1b2c3d4e5f60718",
            snapshotHighWaterMark,
        ])
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)

        await syncClient.syncNow()

        // Everything after the snapshot lives only on the server, no matter
        // how old — a fabricated recent window drops it permanently.
        #expect(try capturedSince() == snapshotHighWaterMark)
    }

    @Test func firstSyncOfAnEmptyBudgetAsksForTheFullServerLog() async throws {
        let (database, path) = try makeDatabase(snapshotTimestamps: [])
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)

        await syncClient.syncNow()

        // With no local floor at all, the only safe request is the server's
        // entire message log (which only spans back to the file's last
        // upload/reset).
        #expect(try capturedSince() == HLCTimestamp.zero.toString())
    }
}
