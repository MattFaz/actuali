import Combine
import Foundation
import GRDB
import Synchronization
import Testing
@testable import Actuali

/// A message has to be stored under the timestamp string the server sent:
/// that string is what the merkle tree hashes, so one that comes back a
/// millisecond off leaves the trees unable to match and the sync never settles.
struct SyncClientTimestampFidelityTests {
    /// A transaction entered on a device whose clock read August 2004, which
    /// is all it takes: the drift guard only refuses timestamps from the
    /// future. Upstream reads these strings exactly; parsing through a
    /// `Double` of seconds read the first two a millisecond low. The same
    /// goes for every device from 2038-01-19 on.
    private static let transaction: [(timestamp: String, column: String, value: String)] = [
        ("2004-08-21T02:21:35.179Z-0000-a1b2c3d4e5f60718", "acct", "S:account-1"),
        ("2004-08-21T02:21:35.179Z-0001-a1b2c3d4e5f60718", "amount", "N:-4250"),
        ("2004-08-21T02:21:35.179Z-0002-a1b2c3d4e5f60718", "date", "N:20040821"),
        ("2004-08-21T02:21:35.179Z-0003-a1b2c3d4e5f60718", "notes", "S:Groceries"),
    ]

    @Test func aTransactionFromAClockIn2004SyncsInOnePass() async throws {
        let (database, path) = try await makeTestDatabase(TestSchema.transactions, TestSchema.messagesCrdt)
        defer { cleanup(path) }

        // The server's messages and its merkle tree over those exact strings.
        var tree = MerkleTree()
        var response = SyncResponse()
        for (counter, field) in Self.transaction.enumerated() {
            // Built from the milliseconds upstream reads, not from `parse`.
            let exact = HLCTimestamp(millis: 1_093_054_895_179, counter: UInt16(counter), node: "a1b2c3d4e5f60718")
            #expect(exact.toString() == field.timestamp)
            tree = tree.inserting(exact)
            var inner = Message()
            inner.dataset = "transactions"
            inner.row = "transaction-1"
            inner.column = field.column
            inner.value = field.value
            var envelope = MessageEnvelope()
            envelope.timestamp = field.timestamp
            envelope.content = try inner.serializedData()
            response.messages.append(envelope)
        }
        response.merkle = try #require(String(data: JSONEncoder().encode(tree.pruned().root), encoding: .utf8))
        let body = try response.serializedData()

        let requests = Mutex(0)
        let serverClient = ActualServerClient(session: StubTransport.session { _ in
            requests.withLock { $0 += 1 }
            return StubTransport.Response(contentType: "application/actual-sync", body: body)
        })
        try await serverClient.configure(serverURL: "https://budget.example.com")
        await serverClient.setToken("test-token")
        let syncClient = SyncClient(serverClient: serverClient, nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")

        await syncClient.syncNow()
        await syncClient.cancelPendingSync()

        #expect(syncClient.stateSubject.value == .idle)
        #expect(requests.withLock { $0 } == 1)
        let stored = try await database.dbQueueForTesting.read { db in
            try String.fetchAll(db, sql: "SELECT timestamp FROM messages_crdt ORDER BY timestamp")
        }
        #expect(stored == Self.transaction.map(\.timestamp))
        let amount = try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT amount FROM transactions WHERE id = 'transaction-1'")
        }
        #expect(amount == -4250)
    }
}
