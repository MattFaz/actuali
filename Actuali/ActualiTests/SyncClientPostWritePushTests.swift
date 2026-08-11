import Foundation
import GRDB
import Testing
@testable import Actuali

/// Captures every body POSTed to /sync/sync and answers with a canned,
/// in-sync response (no messages, empty merkle).
private final class PostWriteCaptureTransport: URLProtocol {
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

/// Issue #139: Wallet/Shortcuts transactions didn't reach the server until the
/// app was opened. `LogTransactionIntent` runs headless and awaits
/// `ensureBudgetReady()`, which awaits the launch task — and that task ends in
/// `syncOnForeground()`. The write then landed milliseconds after a successful
/// sync, so `automaticSync()`'s 1-second rate limit *dropped* the push. The
/// headless process was suspended before anything else synced, leaving the
/// transaction local-only until the next app launch.
///
/// The rate limit exists to coalesce redundant *pull* syncs (several foreground
/// triggers firing at once); it must never swallow a local write.
@Suite(.serialized)
struct SyncClientPostWritePushTests {

    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    isParent INTEGER DEFAULT 0,
                    isChild INTEGER DEFAULT 0,
                    acct TEXT,
                    category TEXT,
                    amount INTEGER,
                    description TEXT,
                    notes TEXT,
                    date INTEGER,
                    imported_description TEXT,
                    financial_id TEXT,
                    transferred_id TEXT,
                    sort_order REAL,
                    tombstone INTEGER DEFAULT 0,
                    cleared INTEGER DEFAULT 0,
                    reconciled INTEGER DEFAULT 0,
                    parent_id TEXT
                )
                """)
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
        return (try BudgetDatabase(path: tempURL), tempURL)
    }

    private func makeSyncClient(database: BudgetDatabase) async throws -> SyncClient {
        PostWriteCaptureTransport.capturedBodies = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PostWriteCaptureTransport.self]
        let serverClient = ActualServerClient(session: URLSession(configuration: config))
        try await serverClient.configure(serverURL: "https://budget.example.com")
        await serverClient.setToken("test-token")

        let syncClient = SyncClient(serverClient: serverClient, nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        return syncClient
    }

    private func transaction(id: String = "txn-1") -> Transaction {
        Transaction(
            id: id,
            accountId: "acct-1",
            date: 20_260_811,
            amount: -820,
            payeeId: "payee-1",
            payeeName: "Blue Bottle",
            categoryId: nil,
            categoryName: nil,
            notes: nil,
            cleared: true,
            reconciled: false,
            transferId: nil,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: nil,
            importedPayee: "BLUE BOTTLE COFFEE"
        )
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// The headless Shortcuts path: launch sync completes, then the intent
    /// writes immediately. The write must still be pushed.
    @Test func writeRightAfterASuccessfulSyncIsStillPushed() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let syncClient = try await makeSyncClient(database: database)

        // Launch sync (BudgetStore.init -> loadTask -> syncOnForeground).
        await syncClient.syncNow()
        #expect(PostWriteCaptureTransport.capturedBodies.count == 1)

        // Intent write, milliseconds later.
        try await syncClient.createTransaction(transaction())

        // The canned server never echoes the messages back, so its merkle stays
        // empty and fullSync recurses on the diff — hence "more than one" rather
        // than exactly one follow-up POST. What matters is that the write was
        // sent at all: before the fix nothing was, and the transaction sat local
        // -only until the app was next opened.
        let pushes = PostWriteCaptureTransport.capturedBodies.dropFirst()
        #expect(!pushes.isEmpty)
        let pushedMessages = try pushes.reduce(0) {
            try $0 + SyncRequest(serializedData: $1).messages.count
        }
        #expect(pushedMessages > 0)
    }

    /// The rate limit still does its job for pull-only triggers: nothing new
    /// locally means no redundant round trip.
    @Test func redundantPullSyncWithNoLocalWritesIsStillRateLimited() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let syncClient = try await makeSyncClient(database: database)

        await syncClient.syncNow()
        #expect(PostWriteCaptureTransport.capturedBodies.count == 1)

        await syncClient.automaticSync()

        #expect(PostWriteCaptureTransport.capturedBodies.count == 1)
    }
}
