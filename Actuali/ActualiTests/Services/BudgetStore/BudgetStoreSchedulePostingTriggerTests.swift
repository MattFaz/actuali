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
    /// A postable monthly schedule whose next date is already in the past.
    /// The monthly recurrence is anchored to the due date itself, not a fixed
    /// calendar day: with a fixed start (e.g. the 15th) the catch-up loop
    /// posts `dueOn`, advances onto today when today IS that day, and posts
    /// again — the test failed on the 15th of every month (posted == 2).
    private func insertDueSchedule(_ db: BudgetDatabase, dueOn: Int) throws {
        let startISO = DayDate(yyyymmdd: dueOn)!.iso
        let conditionsJSON = """
        [{"op":"is","field":"acct","value":"acct-1"},
         {"op":"is","field":"date","value":{"frequency":"monthly","start":"\(startISO)","interval":1}},
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
        let (database, url) = try await makeTestDatabase(
            TestSchema.core + [TestSchema.rules, TestSchema.schedules, TestSchema.schedulesNextDate]
        )
        defer { cleanup(url) }
        let yesterday = DayDate.today().adding(days: -1)
        try insertDueSchedule(database, dueOn: yesterday.yyyymmdd)

        // Built by hand rather than via makeTestStore: the test needs the
        // client itself to fake the state transition below.
        let store = BudgetStore.previewInstance()
        let syncClient = try await makeTestSyncClient(database: database)
        store.configureForTesting(database: database, syncClient: syncClient)

        // Unique budget id per run so the poster's once-per-day gate can't
        // carry over between test runs; scrub both UserDefaults keys after.
        let budgetId = "test-\(UUID().uuidString)"
        let savedBudgetId = UserDefaults.standard.string(forKey: "currentBudgetId")
        defer {
            UserDefaults.standard.set(savedBudgetId, forKey: "currentBudgetId")
            UserDefaults.standard.removeObject(forKey: "lastScheduleRun-\(budgetId)")
        }
        store.currentBudgetId = budgetId

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
            if posted > 0 {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(posted == 1)
    }
}
