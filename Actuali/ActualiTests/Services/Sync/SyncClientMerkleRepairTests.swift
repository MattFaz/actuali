import Foundation
import GRDB
import Synchronization
import Testing
@testable import Actuali

/// One message in the fake server's log.
private struct StubMessage {
    let timestamp: String
    let dataset: String
    let row: String
    let column: String
    let value: String
}

/// A minimal stand-in for actual-server's `/sync/sync`: absorbs the messages the
/// client sends, answers with everything in its log newer than the requested
/// `since`, and reports an HONEST merkle over everything it holds. That last
/// part is the whole point — the client's tree is the one under test.
private final class FakeSyncServer: Sendable {
    private struct State {
        var log: [StubMessage]
        var requestedSince: [String] = []
    }

    private let state: Mutex<State>

    init(log: [StubMessage]) {
        state = Mutex(State(log: log))
    }

    var requestedSince: [String] {
        state.withLock { $0.requestedSince }
    }

    /// A session whose `/sync/sync` is this server.
    var session: URLSession {
        StubTransport.session { [self] request in
            var response = SyncResponse()
            if let decoded = try? SyncRequest(serializedData: request.bodyData),
               !decoded.fileID.isEmpty {
                response.messages = state.withLock { current in
                    current.requestedSince.append(decoded.since)
                    Self.absorb(decoded.messages, into: &current.log)
                    return current.log
                        .filter { $0.timestamp > decoded.since }
                        .map(Self.envelope(for:))
                }
            }
            response.merkle = merkleJSON()
            return StubTransport.Response(
                contentType: "application/actual-sync",
                body: (try? response.serializedData()) ?? Data()
            )
        }
    }

    private static func absorb(_ envelopes: [MessageEnvelope], into log: inout [StubMessage]) {
        for envelope in envelopes {
            guard let inner = try? Message(serializedData: envelope.content),
                  !log.contains(where: { $0.timestamp == envelope.timestamp })
            else { continue }
            log.append(StubMessage(
                timestamp: envelope.timestamp,
                dataset: inner.dataset,
                row: inner.row,
                column: inner.column,
                value: inner.value
            ))
        }
    }

    private static func envelope(for message: StubMessage) -> MessageEnvelope {
        var inner = Message()
        inner.dataset = message.dataset
        inner.row = message.row
        inner.column = message.column
        inner.value = message.value

        var envelope = MessageEnvelope()
        envelope.timestamp = message.timestamp
        envelope.isEncrypted = false
        envelope.content = (try? inner.serializedData()) ?? Data()
        return envelope
    }

    static func merkle(over messages: [StubMessage]) -> MerkleTree {
        var tree = MerkleTree()
        for message in messages {
            guard let parsed = HLCTimestamp.parse(message.timestamp) else { continue }
            tree = tree.inserting(parsed)
        }
        return tree.pruned()
    }

    private func merkleJSON() -> String {
        let log = state.withLock { $0.log }
        guard let data = try? JSONEncoder().encode(Self.merkle(over: log).root),
              let json = String(data: data, encoding: .utf8)
        else { return #"{"hash":0}"# }
        return json
    }
}

/// Issue #121: an install that synced under the pre-#182 fresh-install logic
/// carries a merkle tree it never earned — the old code overwrote the local tree
/// with the server's and recorded parity, so the window of messages that sync
/// skipped became unreachable. The lie is self-consistent (both sides then fold
/// in the same new messages), so every later diff matched and the gap survived
/// re-syncs, "Reset Sync State", and app updates. Missed tombstones and amount
/// edits in that window leave account balances reading high forever.
///
/// The tree must be derived from the local message log, never adopted, so the
/// diff can see the gap and the server can resend it.
struct SyncClientMerkleRepairTests {
    /// Canonical HLC strings: <ISO8601 with millis>-<4 hex counter>-<16 hex node>
    private static let oldMessage = "2026-07-01T09:15:22.000Z-0000-a1b2c3d4e5f60718"
    /// The message the old sync skipped: a $30k transaction deleted on another
    /// client. Never applied locally, so the row still counts toward the balance.
    private static let missedTombstone = "2026-07-18T11:42:07.000Z-0000-a1b2c3d4e5f60718"
    private static let recentMessage = "2026-08-09T08:03:11.000Z-0000-a1b2c3d4e5f60718"

    private static var serverLog: [StubMessage] {
        [
            StubMessage(timestamp: oldMessage, dataset: "transactions", row: "t1", column: "amount", value: "N:1000"),
            StubMessage(timestamp: missedTombstone, dataset: "transactions", row: "t2", column: "tombstone", value: "N:1"),
            StubMessage(timestamp: recentMessage, dataset: "transactions", row: "t2", column: "notes", value: "S:rent"),
        ]
    }

    /// A budget in the poisoned state: one account whose $30k transaction was
    /// deleted upstream, a message log missing that deletion, and a persisted
    /// merkle equal to the server's (what the old adopt path wrote).
    private func makePoisonedDatabase() async throws -> (BudgetDatabase, URL) {
        // The persisted merkle claims the server's full log, and lastSynced
        // claims everything through the newest message.
        let adopted = BudgetDatabase.ClockRecord(
            timestamp: Self.recentMessage,
            merkle: FakeSyncServer.merkle(over: Self.serverLog).root
        )
        let adoptedJSON = try String(data: JSONEncoder().encode(adopted), encoding: .utf8)!

        return try await makeTestDatabase(
            """
            CREATE TABLE accounts (
                id TEXT PRIMARY KEY,
                name TEXT,
                type TEXT,
                offbudget INTEGER DEFAULT 0,
                closed INTEGER DEFAULT 0,
                sort_order REAL,
                tombstone INTEGER DEFAULT 0
            );

            CREATE TABLE transactions (
                id TEXT PRIMARY KEY,
                acct TEXT,
                category TEXT,
                description TEXT,
                notes TEXT,
                amount INTEGER,
                date INTEGER,
                transferred_id TEXT,
                sort_order REAL,
                isParent INTEGER DEFAULT 0,
                isChild INTEGER DEFAULT 0,
                parent_id TEXT,
                tombstone INTEGER DEFAULT 0
            );

            CREATE TABLE messages_crdt (
                id INTEGER PRIMARY KEY,
                timestamp TEXT NOT NULL UNIQUE,
                dataset TEXT NOT NULL,
                row TEXT NOT NULL,
                column TEXT NOT NULL,
                value BLOB NOT NULL
            );

            CREATE TABLE messages_clock (id INTEGER PRIMARY KEY, clock TEXT);

            INSERT INTO accounts (id, name, sort_order) VALUES ('acct-1', 'Checking', 1.0);

            INSERT INTO transactions (id, acct, amount, date, tombstone) VALUES
                ('t1', 'acct-1',    1000, 20260701, 0),
                ('t2', 'acct-1', 3000000, 20260718, 0);
            """,
            // The local log is missing `missedTombstone` — exactly the window the
            // old 24h `since` window skipped.
            """
            INSERT INTO messages_crdt (timestamp, dataset, row, column, value) VALUES
                ('\(Self.oldMessage)', 'transactions', 't1', 'amount', 'N:1000'),
                ('\(Self.recentMessage)', 'transactions', 't1', 'amount', 'N:1000');
            """,
            "INSERT INTO messages_clock (id, clock) VALUES (1, '\(adoptedJSON)')"
        )
    }

    private func makeSyncClient(database: BudgetDatabase, server: FakeSyncServer) async throws -> SyncClient {
        let serverClient = ActualServerClient(session: server.session)
        try await serverClient.configure(serverURL: "https://budget.example.com")
        await serverClient.setToken("test-token")

        let syncClient = SyncClient(serverClient: serverClient, nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        return syncClient
    }

    @Test func syncRecoversTheWindowAnAdoptedMerkleHid() async throws {
        let server = FakeSyncServer(log: Self.serverLog)
        let (database, path) = try await makePoisonedDatabase()
        defer { cleanup(path) }

        // The symptom the reporter saw: $30k of deleted transaction still counted.
        let before = try await database.fetchAccounts().first { $0.id == "acct-1" }
        #expect(before?.balance == 3_001_000)

        let syncClient = try await makeSyncClient(database: database, server: server)
        await syncClient.syncNow()

        // The merkle no longer claims messages sync never fetched, so the diff
        // exposes the gap and the server resends it.
        let after = try await database.fetchAccounts().first { $0.id == "acct-1" }
        #expect(after?.balance == 1000)

        // Reaching back past the poisoned high-water mark is the mechanism: the
        // first request asks from lastSynced, a later one from the divergence.
        #expect(server.requestedSince.count > 1)
        #expect(server.requestedSince.contains { $0 < Self.missedTombstone })
    }

    @Test func derivedMerkleReplacesAPersistedTreeThatDisagreesWithTheLog() async throws {
        let (database, path) = try await makePoisonedDatabase()
        defer { cleanup(path) }

        // Derived from messages_crdt: the two messages actually held, and
        // nothing else.
        var expected = MerkleTree()
        for timestamp in [Self.oldMessage, Self.recentMessage] {
            expected = try expected.inserting(#require(HLCTimestamp.parse(timestamp)))
        }

        let derived = try database.deriveMerkleFromMessageLog()
        #expect(derived.root.hash == expected.pruned().root.hash)
        #expect(derived.root.hash != FakeSyncServer.merkle(over: Self.serverLog).root.hash)
    }
}
