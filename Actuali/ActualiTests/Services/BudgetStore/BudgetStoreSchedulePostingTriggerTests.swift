import Combine
import Foundation
import GRDB
import Testing
@testable import Actuali

/// GH #97: due schedules must post after ANY successful sync, not only when
/// `syncOnForeground()`'s first immediate attempt succeeds. Upstream loot-core
/// runs its schedule service on every sync completion event; Actuali's only
/// trigger was inline in `syncOnForeground()`, so a foreground sync that fails
/// once (network not yet up at wake) and then succeeds via the retry ladder —
/// or any pull-to-refresh / background-push sync — never posted anything.
@MainActor
struct BudgetStoreSchedulePostingTriggerTests {

    /// Upstream-shaped schema for everything the fetch + post + local-apply
    /// pipeline touches (matches SchedulePosterTests, plus messages_crdt so
    /// the real SyncClient can store the CRDT messages it generates).
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

                CREATE TABLE payees (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    transfer_acct TEXT,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE payee_mapping (
                    id TEXT PRIMARY KEY,
                    targetId TEXT
                );

                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    starting_balance_flag INTEGER DEFAULT 0,
                    isParent INTEGER DEFAULT 0,
                    isChild INTEGER DEFAULT 0,
                    acct TEXT,
                    category TEXT,
                    description TEXT,
                    amount INTEGER,
                    notes TEXT,
                    date INTEGER,
                    imported_description TEXT,
                    financial_id TEXT,
                    transferred_id TEXT,
                    cleared INTEGER DEFAULT 0,
                    reconciled INTEGER DEFAULT 0,
                    sort_order REAL,
                    parent_id TEXT,
                    schedule TEXT,
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
            """)
        }
        let database = try BudgetDatabase(path: tempURL)
        return (database, tempURL)
    }

    /// A postable monthly schedule whose next date is already in the past.
    private func insertDueSchedule(_ db: BudgetDatabase, dueOn: Int) throws {
        let conditionsJSON = """
            [{"op":"is","field":"acct","value":"acct-1"},
             {"op":"is","field":"date","value":{"frequency":"monthly","start":"2026-01-15","interval":1}},
             {"op":"is","field":"amount","value":-1500}]
            """
        try db.dbQueueForTesting.write { conn in
            try conn.execute(sql: "INSERT INTO accounts (id, name) VALUES ('acct-1', 'Checking')")
            try conn.execute(sql: """
                INSERT INTO rules (id, stage, conditions_op, conditions, actions)
                VALUES ('rule-1', NULL, 'and', ?, '[]')
                """, arguments: [conditionsJSON])
            try conn.execute(sql: """
                INSERT INTO schedules (id, rule, completed, posts_transaction, tombstone, name)
                VALUES ('sched-1', 'rule-1', 0, 1, 0, 'Rent')
                """)
            try conn.execute(sql: """
                INSERT INTO schedules_next_date
                    (id, schedule_id, local_next_date, local_next_date_ts, base_next_date, base_next_date_ts)
                VALUES ('nd-1', 'sched-1', ?, 1000, ?, 1000)
                """, arguments: [dueOn, dueOn])
        }
    }

    private func postedTransactionCount(_ db: BudgetDatabase) throws -> Int {
        try db.dbQueueForTesting.read { conn in
            try Int.fetchOne(conn, sql: """
                SELECT COUNT(*) FROM transactions
                WHERE schedule = 'sched-1' AND (tombstone = 0 OR tombstone IS NULL)
                """) ?? 0
        }
    }

    /// A sync that succeeds through any path other than syncOnForeground()'s
    /// inline attempt — retry ladder, pull-to-refresh, background push — is
    /// visible only as the client's .syncing → .idle state transition. That
    /// transition must trigger posting.
    @Test func syncSuccessStateTransitionPostsDueSchedules() async throws {
        let (database, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        let yesterday = DayDate.today().adding(days: -1)
        try insertDueSchedule(database, dueOn: yesterday.yyyymmdd)

        let store = BudgetStore.previewInstance()
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        store.configureForTesting(database: database, syncClient: syncClient)

        // Unique budget id per run so the poster's once-per-day gate can't
        // carry over between test runs; scrub both UserDefaults keys after.
        let budgetId = "test-\(UUID().uuidString)"
        let savedBudgetId = UserDefaults.standard.string(forKey: "currentBudgetId")
        let savedToggle = UserDefaults.standard.object(forKey: "postScheduledTransactions")
        defer {
            UserDefaults.standard.set(savedBudgetId, forKey: "currentBudgetId")
            UserDefaults.standard.set(savedToggle, forKey: "postScheduledTransactions")
            UserDefaults.standard.removeObject(forKey: "lastScheduleRun-\(budgetId)")
        }
        store.currentBudgetId = budgetId
        store.postScheduledTransactions = true

        #expect(try postedTransactionCount(database) == 0)

        // Simulate a successful sync completing outside syncOnForeground():
        // performSync() is the only sender of .syncing followed by .idle.
        syncClient.stateSubject.send(.syncing)
        syncClient.stateSubject.send(.idle)

        // The trigger hops through the main queue and the poster actor; poll
        // rather than sleep a fixed amount.
        var posted = 0
        for _ in 0..<200 {
            posted = try postedTransactionCount(database)
            if posted > 0 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(posted == 1)
    }
}
