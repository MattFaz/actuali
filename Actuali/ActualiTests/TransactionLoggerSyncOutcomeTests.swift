import Foundation
import GRDB
import Testing
@testable import Actuali

/// Answers /sync/sync either with a valid in-sync response or with a network
/// failure, so the headless write path can be exercised against a reachable
/// and an unreachable server.
private final class SyncOutcomeTransport: URLProtocol {
    nonisolated(unsafe) static var failWithOffline = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if Self.failWithOffline {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
            return
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
        SyncOutcomeTransport.failWithOffline = !serverReachable
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
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id FROM transactions WHERE tombstone = 0")
        }
        #expect(rows.count == 1)
        #expect(rows.first?["id"] == result.transaction.id)
    }
}
