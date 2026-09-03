import Foundation
import GRDB
import Testing
@testable import Actuali

/// Answers /sync/sync either with a valid in-sync response or with a network
/// failure, so the headless write path can be exercised against a reachable
/// and an unreachable server.
private final class SyncOutcomeTransport: URLProtocol {
    nonisolated(unsafe) static var failWithOffline = false
    /// Timestamps the client has pushed. A real server folds the messages it
    /// receives into its own tree before answering, so answering with a merkle
    /// over these is what lets the client see itself as in sync — a stub that
    /// always claimed an empty tree would leave every sync out of sync.
    nonisolated(unsafe) static var absorbed: Set<String> = []

    static func reset(failWithOffline: Bool) {
        self.failWithOffline = failWithOffline
        absorbed = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if Self.failWithOffline {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
            return
        }

        var response = SyncResponse()
        if let decoded = try? SyncRequest(serializedData: Self.readBody(request)) {
            Self.absorbed.formUnion(decoded.messages.map(\.timestamp))
        }
        response.merkle = Self.merkleJSON()
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

    /// URLSession hands POST bodies to URLProtocol as a stream, not httpBody.
    private static func readBody(_ request: URLRequest) -> Data {
        guard let stream = request.httpBodyStream else { return request.httpBody ?? Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        let bufferSize = 16 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            body.append(buffer, count: read)
        }
        return body
    }

    private static func merkleJSON() -> String {
        var tree = MerkleTree()
        for timestamp in absorbed.sorted() {
            guard let parsed = HLCTimestamp.parse(timestamp) else { continue }
            tree = tree.inserting(parsed)
        }
        guard let data = try? JSONEncoder().encode(tree.pruned().root),
              let json = String(data: data, encoding: .utf8)
        else { return #"{"hash":0}"# }
        return json
    }
}

/// Issue #139: the Shortcut used to report a plain success even when the row
/// never left the phone. `logTransaction` now reports whether the push landed
/// so `LogTransactionIntent` can say "Saved locally" instead.
@MainActor
@Suite(.serialized)
struct TransactionLoggerSyncOutcomeTests {

    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    starting_balance_flag INTEGER DEFAULT 0,
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
                CREATE TABLE payees (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    transfer_acct TEXT,
                    tombstone INTEGER DEFAULT 0
                )
                """)
            try db.execute(sql: """
                CREATE TABLE payee_mapping (
                    id TEXT PRIMARY KEY,
                    targetId TEXT
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

    private func makeStore(database: BudgetDatabase, serverReachable: Bool) async throws -> BudgetStore {
        SyncOutcomeTransport.reset(failWithOffline: !serverReachable)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SyncOutcomeTransport.self]
        let serverClient = ActualServerClient(session: URLSession(configuration: config))
        try await serverClient.configure(serverURL: "https://budget.example.com")
        await serverClient.setToken("test-token")

        let syncClient = SyncClient(serverClient: serverClient, nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")

        let store = BudgetStore.previewInstance()
        store.configureForTesting(database: database, syncClient: syncClient)
        return store
    }

    private func log(to store: BudgetStore) async throws -> TransactionLogger.Result {
        try await TransactionLogger(store: store).logTransaction(
            accountId: "acct-1",
            amountCents: -820,
            rawMerchant: "BLUE BOTTLE COFFEE",
            notes: nil,
            date: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test func reachableServerReportsTheWriteAsSynced() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, serverReachable: true)

        let result = try await log(to: store)

        #expect(result.synced)
    }

    /// Unreachable server: the row is still written (nothing is lost), but the
    /// caller is told it hasn't landed so the banner can say so.
    @Test func unreachableServerReportsTheWriteAsUnsynced() async throws {
        let (database, url) = try makeDatabase()
        defer { cleanup(url) }
        let store = try await makeStore(database: database, serverReachable: false)

        let result = try await log(to: store)

        #expect(!result.synced)

        let queue = try DatabaseQueue(path: url.path)
        let rows = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id FROM transactions WHERE tombstone = 0")
        }
        #expect(rows.count == 1)
        #expect(rows.first?["id"] == result.transaction.id)
    }
}
