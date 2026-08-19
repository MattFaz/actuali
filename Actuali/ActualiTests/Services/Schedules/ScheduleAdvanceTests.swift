import Foundation
import GRDB
import Testing
@testable import Actuali

/// Pins `SyncClient.advanceScheduleNextDate` — the CRDT write that advances a
/// schedule after posting. It mirrors loot-core setNextDate (non-reset
/// branch): `local_next_date` moves and `local_next_date_ts` copies the
/// CURRENT `base_next_date_ts`, so the local override stays valid (per the
/// v_schedules CASE rule) until another client resets the base. The base
/// columns must never be touched.
struct ScheduleAdvanceTests {

    // MARK: - Fixtures

    /// Schema mirrors ScheduleFetchTests (schedules tables + the tables
    /// fetchPostableSchedules reads) plus messages_crdt for the sync client.
    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")

        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    offbudget INTEGER DEFAULT 0,
                    closed INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE payee_mapping (
                    id TEXT PRIMARY KEY,
                    targetId TEXT
                );

                CREATE TABLE rules (
                    id TEXT PRIMARY KEY,
                    stage TEXT,
                    conditions_op TEXT DEFAULT 'and',
                    conditions TEXT,
                    actions TEXT,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE schedules (
                    id TEXT PRIMARY KEY,
                    rule TEXT,
                    active INTEGER DEFAULT 0,
                    completed INTEGER DEFAULT 0,
                    posts_transaction INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0,
                    name TEXT
                );

                CREATE TABLE schedules_next_date (
                    id TEXT PRIMARY KEY,
                    schedule_id TEXT,
                    local_next_date INTEGER,
                    local_next_date_ts INTEGER,
                    base_next_date INTEGER,
                    base_next_date_ts INTEGER
                );

                CREATE TABLE messages_crdt (
                    id INTEGER PRIMARY KEY,
                    timestamp TEXT NOT NULL UNIQUE,
                    dataset TEXT NOT NULL,
                    row TEXT NOT NULL,
                    column TEXT NOT NULL,
                    value BLOB NOT NULL
                );
                """)
        }
        let database = try BudgetDatabase(path: tempURL)
        try database.dbQueueForTesting.write { db in
            try db.execute(sql: "INSERT INTO accounts (id, name) VALUES ('acct-1', 'Checking')")
            try db.execute(sql: "INSERT INTO payee_mapping (id, targetId) VALUES ('payee-1', 'payee-1')")
        }
        return (database, tempURL)
    }

    /// Sync client wired to a real database. The server client is
    /// unconfigured, so the post-write automatic sync fails fast and locally
    /// without touching the network. (Same pattern as
    /// SyncClientSetBudgetAmountTests.)
    private func makeSyncClient(database: BudgetDatabase) async throws -> SyncClient {
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        return syncClient
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Inserts a full postable schedule (rule + schedule + next-date row).
    private func insertSchedule(
        _ db: BudgetDatabase,
        id: String = "sched-1",
        localNextDate: Int = 20260801,
        localNextDateTs: Int64 = 1_000,
        baseNextDate: Int = 20260801,
        baseNextDateTs: Int64 = 1_000
    ) throws {
        let conditionsJSON = """
            [{"op":"is","field":"acct","value":"acct-1"},
             {"op":"is","field":"description","value":"payee-1"},
             {"op":"isapprox","field":"amount","value":-1500},
             {"op":"is","field":"date","value":{"frequency":"monthly","start":"2026-01-15","interval":1}}]
            """
        try db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO rules (id, stage, conditions_op, conditions, actions)
                VALUES (?, NULL, 'and', ?, '[]')
                """, arguments: ["rule-\(id)", conditionsJSON])
            try conn.execute(sql: """
                INSERT INTO schedules (id, rule, completed, posts_transaction, tombstone, name)
                VALUES (?, ?, 0, 1, 0, 'Rent')
                """, arguments: [id, "rule-\(id)"])
            try conn.execute(sql: """
                INSERT INTO schedules_next_date
                    (id, schedule_id, local_next_date, local_next_date_ts, base_next_date, base_next_date_ts)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: ["nd-\(id)", id, localNextDate, localNextDateTs, baseNextDate, baseNextDateTs])
        }
    }

    private func nextDateRow(path: URL, id: String = "nd-sched-1") throws -> Row {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM schedules_next_date WHERE id = ?", arguments: [id])!
        }
    }

    private func messageRows(path: URL) throws -> [Row] {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM messages_crdt ORDER BY timestamp")
        }
    }

    // MARK: - Message shape

    @Test func emitsExactlyTwoFieldMessagesWithNSerialization() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        try insertSchedule(database)
        let syncClient = try await makeSyncClient(database: database)

        try await syncClient.advanceScheduleNextDate(
            nextDateRowId: "nd-sched-1", newNextDate: 20260901, baseNextDateTs: 1_000
        )

        let messages = try messageRows(path: path)
        #expect(messages.count == 2)
        for message in messages {
            #expect(message["dataset"] == "schedules_next_date")
            #expect(message["row"] == "nd-sched-1")
        }
        let byColumn = Dictionary(uniqueKeysWithValues: messages.map {
            ($0["column"] as String? ?? "", $0["value"] as String? ?? "")
        })
        #expect(byColumn["local_next_date"] == "N:20260901")
        #expect(byColumn["local_next_date_ts"] == "N:1000")
    }

    // MARK: - Local row state

    @Test func updatesLocalColumnsAndLeavesBaseUntouched() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        // Local override currently stale (ts 500 != base ts 1000): the advance
        // must both move local_next_date AND re-validate it by copying the
        // base ts — while never touching the base columns.
        try insertSchedule(
            database,
            localNextDate: 20260701, localNextDateTs: 500,
            baseNextDate: 20260801, baseNextDateTs: 1_000
        )
        let syncClient = try await makeSyncClient(database: database)

        try await syncClient.advanceScheduleNextDate(
            nextDateRowId: "nd-sched-1", newNextDate: 20260901, baseNextDateTs: 1_000
        )

        let row = try nextDateRow(path: path)
        #expect(row["local_next_date"] == 20260901)
        #expect(row["local_next_date_ts"] == 1_000)
        #expect(row["base_next_date"] == 20260801)
        #expect(row["base_next_date_ts"] == 1_000)
        #expect(row["schedule_id"] == "sched-1")
    }

    // MARK: - Integration with fetchPostableSchedules (v_schedules CASE)

    @Test func fetchPostableSchedulesSeesAdvancedDate() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        try insertSchedule(database)
        let syncClient = try await makeSyncClient(database: database)

        let before = try database.fetchPostableSchedules()
        #expect(before.first?.nextDate.yyyymmdd == 20260801)
        let schedule = try #require(before.first)

        try await syncClient.advanceScheduleNextDate(
            nextDateRowId: schedule.nextDateRowId,
            newNextDate: 20260915,
            baseNextDateTs: schedule.baseNextDateTs
        )

        // local_next_date_ts == base_next_date_ts, so the local override wins.
        let after = try database.fetchPostableSchedules()
        #expect(after.count == 1)
        #expect(after.first?.nextDate.yyyymmdd == 20260915)
        #expect(after.first?.baseNextDateTs == 1_000)
    }

    // MARK: - Guards

    @Test func unconfiguredClientThrowsWithoutWriting() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        try insertSchedule(database)
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")

        await #expect(throws: SyncError.self) {
            try await syncClient.advanceScheduleNextDate(
                nextDateRowId: "nd-sched-1", newNextDate: 20260901, baseNextDateTs: 1_000
            )
        }
        #expect(try messageRows(path: path).isEmpty)
        #expect(try nextDateRow(path: path)["local_next_date"] == 20260801)
    }
}
