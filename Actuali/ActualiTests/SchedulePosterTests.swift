import Foundation
import Testing
import GRDB
@testable import Actuali

/// Recording fake for SchedulePostingActions. Mirrors the real SyncClient's
/// observable side effects on the local DB: createTransaction inserts the
/// transaction row (so the poster's hasTransaction dedup guard sees it, same
/// as production) and advanceScheduleNextDate applies the local_next_date
/// override to the schedules_next_date row.
private final class RecordingActions: SchedulePostingActions {
    let database: BudgetDatabase
    var created: [Transaction] = []
    var advances: [(rowId: String, newNextDate: Int, baseTs: Int64)] = []
    /// Schedule ids whose createTransaction should throw (schedule-level error).
    var failingScheduleIds: Set<String> = []

    struct FakeError: Error {}

    init(database: BudgetDatabase) {
        self.database = database
    }

    func createTransaction(_ transaction: Transaction) async throws {
        if let schedule = transaction.schedule, failingScheduleIds.contains(schedule) {
            throw FakeError()
        }
        try await database.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, date, amount, description, schedule, cleared, tombstone)
                VALUES (?, ?, ?, ?, ?, ?, ?, 0)
                """, arguments: [
                    transaction.id, transaction.accountId, transaction.date,
                    transaction.amount, transaction.payeeId, transaction.schedule,
                    transaction.cleared ? 1 : 0,
                ])
        }
        created.append(transaction)
    }

    func advanceScheduleNextDate(nextDateRowId: String, newNextDate: Int, baseNextDateTs: Int64) async throws {
        try await database.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                UPDATE schedules_next_date
                SET local_next_date = ?, local_next_date_ts = ?
                WHERE id = ?
                """, arguments: [newNextDate, baseNextDateTs, nextDateRowId])
        }
        advances.append((rowId: nextDateRowId, newNextDate: newNextDate, baseTs: baseNextDateTs))
    }
}

@MainActor
struct SchedulePosterTests {

    // MARK: - Fixtures

    private static let budgetId = "budget-1"
    /// Fixed "today" for every test: 2026-07-15 (an occurrence day of the
    /// monthly fixtures, which start 2026-01-15).
    private static let today = DayDate(yyyymmdd: 20260715)!

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
                    isParent INTEGER DEFAULT 0,
                    isChild INTEGER DEFAULT 0,
                    acct TEXT,
                    category TEXT,
                    description TEXT,
                    amount INTEGER,
                    notes TEXT,
                    date INTEGER,
                    imported_description TEXT,
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
        try database.dbQueueForTesting.write { db in
            try db.execute(sql: "INSERT INTO accounts (id, name) VALUES ('acct-1', 'Checking')")
            try db.execute(sql: "INSERT INTO payee_mapping (id, targetId) VALUES ('payee-1', 'payee-1')")
        }
        return (database, tempURL)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func makePoster(_ db: BudgetDatabase) -> (SchedulePoster, RecordingActions, UserDefaults) {
        let actions = RecordingActions(database: db)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let poster = SchedulePoster(database: db, actions: actions, defaults: defaults)
        return (poster, actions, defaults)
    }

    private static let monthlyDateJSON = """
        {"op":"is","field":"date","value":{"frequency":"monthly","start":"2026-01-15","interval":1}}
        """

    /// Inserts a postable schedule (rule + schedule + next-date row).
    /// Defaults: recurring monthly on the 15th, acct-1, payee-1, -1500.
    private func insertSchedule(
        _ db: BudgetDatabase,
        id: String = "sched-1",
        conditions: String? = nil,
        nextDate: Int
    ) throws {
        let conditionsJSON = conditions ?? """
            [{"op":"is","field":"acct","value":"acct-1"},
             {"op":"is","field":"description","value":"payee-1"},
             {"op":"isapprox","field":"amount","value":-1500},
             \(Self.monthlyDateJSON)]
            """
        try db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO rules (id, stage, conditions_op, conditions, actions)
                VALUES (?, NULL, 'and', ?, '[]')
                """, arguments: ["rule-\(id)", conditionsJSON])
            try conn.execute(sql: """
                INSERT INTO schedules (id, rule, completed, posts_transaction, tombstone, name)
                VALUES (?, ?, 0, 1, 0, ?)
                """, arguments: [id, "rule-\(id)", "Schedule \(id)"])
            try conn.execute(sql: """
                INSERT INTO schedules_next_date
                    (id, schedule_id, local_next_date, local_next_date_ts, base_next_date, base_next_date_ts)
                VALUES (?, ?, ?, 1000, ?, 1000)
                """, arguments: ["nd-\(id)", id, nextDate, nextDate])
        }
    }

    private func insertTransaction(
        _ db: BudgetDatabase, id: String, schedule: String, date: Int
    ) throws {
        try db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, date, amount, schedule, tombstone)
                VALUES (?, 'acct-1', ?, -1500, ?, 0)
                """, arguments: [id, date, schedule])
        }
    }

    // MARK: - Posting

    @Test func singleDueSchedulePostsOnceAndAdvancesPastToday() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try insertSchedule(db, nextDate: 20260715)
        let (poster, actions, _) = makePoster(db)

        let posted = await poster.runIfNeeded(budgetId: Self.budgetId, today: Self.today)

        #expect(posted == 1)
        #expect(actions.created.count == 1)
        let txn = try #require(actions.created.first)
        #expect(txn.accountId == "acct-1")
        #expect(txn.payeeId == "payee-1")
        #expect(txn.amount == -1500)
        #expect(txn.date == 20260715)
        #expect(txn.schedule == "sched-1")
        #expect(txn.cleared == false)
        #expect(txn.reconciled == false)
        #expect(txn.tombstone == false)

        #expect(actions.advances.count == 1)
        let advance = try #require(actions.advances.first)
        #expect(advance.rowId == "nd-sched-1")
        #expect(advance.newNextDate == 20260815)
        #expect(advance.newNextDate > Self.today.yyyymmdd)
        #expect(advance.baseTs == 1000)
    }

    @Test func threeMissedMonthsCatchUpWithAdvancesBetweenEach() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try insertSchedule(db, nextDate: 20260515)
        let (poster, actions, _) = makePoster(db)

        let posted = await poster.runIfNeeded(budgetId: Self.budgetId, today: Self.today)

        #expect(posted == 3)
        #expect(actions.created.map(\.date) == [20260515, 20260615, 20260715])
        #expect(actions.advances.map(\.newNextDate) == [20260615, 20260715, 20260815])
    }

    @Test func alreadyPaidOccurrenceAdvancesWithoutPosting() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try insertSchedule(db, nextDate: 20260715)
        try insertTransaction(db, id: "t-paid", schedule: "sched-1", date: 20260715)
        let (poster, actions, _) = makePoster(db)

        let posted = await poster.runIfNeeded(budgetId: Self.budgetId, today: Self.today)

        #expect(posted == 0)
        #expect(actions.created.isEmpty)
        #expect(actions.advances.map(\.newNextDate) == [20260815])
    }

    // MARK: - One-off schedules

    private static let oneOffConditions = """
        [{"op":"is","field":"acct","value":"acct-1"},
         {"op":"is","field":"description","value":"payee-1"},
         {"op":"is","field":"amount","value":-1500},
         {"op":"is","field":"date","value":"2026-07-01"}]
        """

    @Test func dueOneOffPostsOnceAndNeverAdvances() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try insertSchedule(db, conditions: Self.oneOffConditions, nextDate: 20260701)
        let (poster, actions, _) = makePoster(db)

        let posted = await poster.runIfNeeded(budgetId: Self.budgetId, today: Self.today)

        #expect(posted == 1)
        #expect(actions.created.map(\.date) == [20260701])
        #expect(actions.advances.isEmpty)
    }

    @Test func paidOneOffNeitherPostsNorAdvances() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try insertSchedule(db, conditions: Self.oneOffConditions, nextDate: 20260701)
        try insertTransaction(db, id: "t-paid", schedule: "sched-1", date: 20260701)
        let (poster, actions, _) = makePoster(db)

        let posted = await poster.runIfNeeded(budgetId: Self.budgetId, today: Self.today)

        #expect(posted == 0)
        #expect(actions.created.isEmpty)
        #expect(actions.advances.isEmpty)
    }

    // MARK: - Gate

    @Test func nothingDueDoesNothingButStillSetsGate() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try insertSchedule(db, nextDate: 20260815)
        let (poster, actions, defaults) = makePoster(db)

        let posted = await poster.runIfNeeded(budgetId: Self.budgetId, today: Self.today)

        #expect(posted == 0)
        #expect(actions.created.isEmpty)
        #expect(actions.advances.isEmpty)
        #expect(defaults.integer(forKey: "lastScheduleRun-budget-1") == 20260715)
    }

    @Test func secondRunSameDayIsGatedButNextDayRunsAgain() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try insertSchedule(db, nextDate: 20260715)
        let (poster, actions, defaults) = makePoster(db)

        let first = await poster.runIfNeeded(budgetId: Self.budgetId, today: Self.today)
        #expect(first == 1)
        #expect(defaults.integer(forKey: "lastScheduleRun-budget-1") == 20260715)

        let second = await poster.runIfNeeded(budgetId: Self.budgetId, today: Self.today)
        #expect(second == 0)
        #expect(actions.created.count == 1)   // no new posts on the gated run

        // Next calendar day: the gate no longer matches, so the pass runs
        // (nothing is due — the fake applied the advance to the nd row — but
        // the clean pass moves the gate forward).
        let tomorrow = Self.today.adding(days: 1)
        let third = await poster.runIfNeeded(budgetId: Self.budgetId, today: tomorrow)
        #expect(third == 0)
        #expect(actions.created.count == 1)
        #expect(defaults.integer(forKey: "lastScheduleRun-budget-1") == tomorrow.yyyymmdd)
    }

    // MARK: - Failure isolation

    @Test func fetchErrorReturnsZeroAndLeavesGateUnset() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try insertSchedule(db, nextDate: 20260715)
        let (poster, actions, defaults) = makePoster(db)

        // fetchPostableSchedules reads the accounts table (closed-account set)
        // without a tableExists guard — dropping it makes the fetch throw for
        // real, exercising the poster's try? swallow path.
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: "DROP TABLE accounts")
        }

        let posted = await poster.runIfNeeded(budgetId: Self.budgetId, today: Self.today)

        #expect(posted == 0)
        #expect(actions.created.isEmpty)
        #expect(actions.advances.isEmpty)
        #expect(defaults.integer(forKey: "lastScheduleRun-budget-1") == 0)

        // Gate untouched: same day, DB repaired, the pass runs and posts.
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    offbudget INTEGER DEFAULT 0,
                    closed INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0
                )
                """)
            try conn.execute(sql: "INSERT INTO accounts (id, name) VALUES ('acct-1', 'Checking')")
        }
        let retried = await poster.runIfNeeded(budgetId: Self.budgetId, today: Self.today)
        #expect(retried == 1)
        #expect(defaults.integer(forKey: "lastScheduleRun-budget-1") == 20260715)
    }

    @Test func scheduleErrorSkipsGateButOtherSchedulesStillProcess() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try insertSchedule(db, id: "sched-a", nextDate: 20260715)
        try insertSchedule(db, id: "sched-b", nextDate: 20260715)
        let (poster, actions, defaults) = makePoster(db)
        actions.failingScheduleIds = ["sched-a"]

        let first = await poster.runIfNeeded(budgetId: Self.budgetId, today: Self.today)

        // B still posted despite A's failure; the dirty pass must NOT set the gate.
        #expect(first == 1)
        #expect(actions.created.map(\.schedule) == ["sched-b"])
        #expect(defaults.integer(forKey: "lastScheduleRun-budget-1") == 0)

        // Same day, error gone: the pass runs again, posts A, and B (already
        // paid, nd row already advanced) is untouched. Clean pass sets the gate.
        actions.failingScheduleIds = []
        let second = await poster.runIfNeeded(budgetId: Self.budgetId, today: Self.today)
        #expect(second == 1)
        #expect(actions.created.map(\.schedule) == ["sched-b", "sched-a"])
        #expect(defaults.integer(forKey: "lastScheduleRun-budget-1") == 20260715)
    }

    // MARK: - Iteration cap

    @Test func dailySchedule300DaysBehindStopsAtIterationCap() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        let start = Self.today.adding(days: -300)
        try insertSchedule(db, conditions: """
            [{"op":"is","field":"acct","value":"acct-1"},
             {"op":"is","field":"description","value":"payee-1"},
             {"op":"is","field":"amount","value":-1500},
             {"op":"is","field":"date","value":{"frequency":"daily","start":"\(start.iso)","interval":1}}]
            """, nextDate: start.yyyymmdd)
        let (poster, actions, _) = makePoster(db)

        let posted = await poster.runIfNeeded(budgetId: Self.budgetId, today: Self.today)

        #expect(posted == 200)
        #expect(actions.created.count == 200)
        #expect(actions.created.first?.date == start.yyyymmdd)
        #expect(actions.created.last?.date == start.adding(days: 199).yyyymmdd)
    }

    // MARK: - Amounts

    @Test func rangeAmountPostsJSRoundedMidpoint() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        // JS Math.round((-3 + -4) / 2) == -3 (half rounds toward +∞).
        try insertSchedule(db, conditions: """
            [{"op":"is","field":"acct","value":"acct-1"},
             {"op":"isbetween","field":"amount","value":{"num1":-3,"num2":-4}},
             \(Self.monthlyDateJSON)]
            """, nextDate: 20260715)
        let (poster, actions, _) = makePoster(db)

        let posted = await poster.runIfNeeded(budgetId: Self.budgetId, today: Self.today)

        #expect(posted == 1)
        #expect(actions.created.first?.amount == -3)
    }

    @Test func missingAmountConditionPostsZero() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try insertSchedule(db, conditions: """
            [{"op":"is","field":"acct","value":"acct-1"},
             \(Self.monthlyDateJSON)]
            """, nextDate: 20260715)
        let (poster, actions, _) = makePoster(db)

        let posted = await poster.runIfNeeded(budgetId: Self.budgetId, today: Self.today)

        #expect(posted == 1)
        #expect(actions.created.first?.amount == 0)
    }
}
