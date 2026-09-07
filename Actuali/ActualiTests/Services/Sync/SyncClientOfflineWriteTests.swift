import Foundation
import GRDB
import Testing
@testable import Actuali

/// A server that accepts the connection and then never answers in time — what
/// an unreachable self-hosted server looks like to URLSession (the request
/// hangs until the timeout rather than failing fast).
private final class StallingSyncTransport: URLProtocol {
    /// Requests hang until the test opens the gate rather than for a fixed
    /// number of seconds. A wall-clock bound can't tell "the caller awaited
    /// the push" from "the runner was starved": CI measured 4s across a window
    /// that takes 20ms locally and failed a 3s bound with nothing wrong. Held
    /// open, a caller that awaits the push simply never returns, which the
    /// test's time limit catches no matter how slow the machine is.
    private static let gate = NSCondition()
    nonisolated(unsafe) private static var isOpen = false
    nonisolated(unsafe) private static var attempts = 0
    nonisolated(unsafe) private static var completions = 0

    /// Safety net so a request left in flight by an earlier test can't hold a
    /// URLSession thread for the life of the suite.
    private static let maxStall: TimeInterval = 60

    static func reset() {
        gate.lock()
        isOpen = false
        attempts = 0
        completions = 0
        gate.unlock()
    }

    /// Let every stalled request fail so its thread unwinds.
    static func release() {
        gate.lock()
        isOpen = true
        gate.broadcast()
        gate.unlock()
    }

    static var attemptCount: Int {
        gate.lock()
        defer { gate.unlock() }
        return attempts
    }

    /// Requests that have finished stalling — zero for as long as the gate is
    /// shut, so a caller that returned while this is zero cannot have waited
    /// for the server to answer.
    static var completionCount: Int {
        gate.lock()
        defer { gate.unlock() }
        return completions
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.gate.lock()
        Self.attempts += 1
        let deadline = Date(timeIntervalSinceNow: Self.maxStall)
        // wait(until:) returns false once the deadline passes.
        while !Self.isOpen, Self.gate.wait(until: deadline) {}
        Self.completions += 1
        Self.gate.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }

    override func stopLoading() {}
}

/// Issue #125: adding a transaction hung for the full network timeout when the
/// server was unreachable. The row and its CRDT messages are committed locally
/// before the push, so the push must not be awaited by the caller — the write
/// returns immediately and the sync is deferred to the retry ladder.
@Suite(.serialized)
struct SyncClientOfflineWriteTests {

    /// transactions and messages_crdt normally come from the downloaded budget
    /// file, so create them with the upstream schema.
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

    /// Sync client whose every request stalls, standing in for a server that
    /// is down or off-network.
    private func makeSyncClient(database: BudgetDatabase) async throws -> SyncClient {
        StallingSyncTransport.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StallingSyncTransport.self]
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

    private func transaction(id: String) -> Transaction {
        Transaction(
            id: id,
            accountId: "acct-1",
            date: 20260811,
            amount: -1234,
            payeeId: "payee-1",
            payeeName: "Coffee",
            categoryId: "cat-1",
            categoryName: nil,
            notes: nil,
            cleared: false,
            reconciled: false,
            transferId: nil,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: nil,
            importedPayee: nil
        )
    }

    private func rowExists(_ database: BudgetDatabase, id: String) throws -> Bool {
        try database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions WHERE id = ?", arguments: [id]) ?? 0
        } > 0
    }

    /// The whole bug: the caller must not wait on the network round trip.
    /// The time limit is half the assertion — the gate stays shut for the
    /// duration of the test, so a caller that awaits the push never returns at
    /// all rather than returning slowly.
    @Test(.timeLimit(.minutes(1)))
    func createTransactionReturnsWithoutWaitingForTheServer() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)
        defer { StallingSyncTransport.release() }

        try await syncClient.createTransaction(transaction(id: "tx-offline-1"))

        // Returned while the server is still hanging: nothing has been allowed
        // to answer yet, so the push cannot have been awaited.
        #expect(StallingSyncTransport.completionCount == 0, "createTransaction waited for the unreachable server to answer")
        // Local-first: the transaction is already durable on return.
        #expect(try rowExists(database, id: "tx-offline-1"))
    }

    /// Deferred, not dropped: the push still goes out, just off the caller's
    /// thread.
    @Test func pushStillHappensAfterTheWriteReturns() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)
        defer { StallingSyncTransport.release() }

        try await syncClient.createTransaction(transaction(id: "tx-offline-2"))

        var observed = StallingSyncTransport.attemptCount
        for _ in 0..<40 where observed == 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
            observed = StallingSyncTransport.attemptCount
        }
        #expect(observed >= 1, "the deferred sync never reached the server")
    }
}
