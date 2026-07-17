import Foundation
import Testing
import GRDB
@testable import Actuali

/// Pins `BudgetDatabase.fetchPostableSchedules()` and the dedup guard
/// `hasTransaction(scheduleId:onOrAfter:)`. These feed the SchedulePoster,
/// which writes to users' real servers — every doubt case must be a silent
/// skip, never a throw and never a bogus schedule.
@MainActor
struct ScheduleFetchTests {

    // MARK: - Fixtures

    private func makeDatabase(includeScheduleTables: Bool = true) throws -> (BudgetDatabase, URL) {
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

                CREATE TABLE categories (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE category_mapping (
                    id TEXT PRIMARY KEY,
                    transferId TEXT
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
            """)
            if includeScheduleTables {
                try db.execute(sql: """
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
        }
        let database = try BudgetDatabase(path: tempURL)
        try database.dbQueueForTesting.write { db in
            try db.execute(sql: "INSERT INTO accounts (id, name) VALUES ('acct-1', 'Checking')")
            try db.execute(sql: "INSERT INTO accounts (id, name, closed) VALUES ('acct-closed', 'Old', 1)")
            try db.execute(sql: "INSERT INTO payee_mapping (id, targetId) VALUES ('payee-1', 'payee-1')")
            try db.execute(sql: "INSERT INTO payee_mapping (id, targetId) VALUES ('payee-merged', 'payee-target')")
        }
        return (database, tempURL)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static let monthlyDateJSON = """
        {"op":"is","field":"date","value":{"frequency":"monthly","start":"2026-01-15","interval":1}}
        """

    /// Inserts a full schedule (rule + schedule + next-date row). Conditions
    /// default to a postable recurring monthly schedule on acct-1.
    private func insertSchedule(
        _ db: BudgetDatabase,
        id: String = "sched-1",
        name: String? = "Rent",
        postsTransaction: Int = 1,
        completed: Int = 0,
        tombstone: Int = 0,
        conditions: String? = nil,
        localNextDate: Int? = 20260801,
        localNextDateTs: Int64? = 1_000,
        baseNextDate: Int? = 20260801,
        baseNextDateTs: Int64? = 1_000
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
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [id, "rule-\(id)", completed, postsTransaction, tombstone, name])
            try conn.execute(sql: """
                INSERT INTO schedules_next_date
                    (id, schedule_id, local_next_date, local_next_date_ts, base_next_date, base_next_date_ts)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: ["nd-\(id)", id, localNextDate, localNextDateTs, baseNextDate, baseNextDateTs])
        }
    }

    // MARK: - Extraction

    @Test func happyPathExtractsAllFields() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try insertSchedule(db)

        let schedules = try db.fetchPostableSchedules()
        #expect(schedules.count == 1)
        let s = try #require(schedules.first)
        #expect(s.id == "sched-1")
        #expect(s.name == "Rent")
        #expect(s.accountId == "acct-1")
        #expect(s.payeeId == "payee-1")
        #expect(s.amount == .fixed(-1500))
        #expect(s.nextDate.yyyymmdd == 20260801)
        #expect(s.nextDateRowId == "nd-sched-1")
        #expect(s.baseNextDateTs == 1_000)
        guard case .recurring(let config) = s.dateCondition else {
            Issue.record("expected recurring date condition")
            return
        }
        #expect(config.frequency == .monthly)
        #expect(config.start.iso == "2026-01-15")
        #expect(config.interval == 1)
    }

    @Test func fixedDateConditionParses() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try insertSchedule(db, conditions: """
            [{"op":"is","field":"acct","value":"acct-1"},
             {"op":"is","field":"date","value":"2026-07-01"}]
            """)

        let schedules = try db.fetchPostableSchedules()
        let s = try #require(schedules.first)
        guard case .fixed(let day) = s.dateCondition else {
            Issue.record("expected fixed date condition")
            return
        }
        #expect(day.iso == "2026-07-01")
        #expect(s.payeeId == nil)
        #expect(s.amount == nil)
    }

    @Test func rangeAmountParsesFromIsbetween() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try insertSchedule(db, conditions: """
            [{"op":"is","field":"acct","value":"acct-1"},
             {"op":"isbetween","field":"amount","value":{"num1":-1500,"num2":-2500}},
             \(Self.monthlyDateJSON)]
            """)

        let schedules = try db.fetchPostableSchedules()
        #expect(schedules.first?.amount == .range(-1500, -2500))
    }

    /// loot-core's v_schedules resolves the payee condition through
    /// payee_mapping (pm.targetId), so a merged payee posts to its target.
    @Test func payeeResolvesThroughPayeeMapping() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try insertSchedule(db, conditions: """
            [{"op":"is","field":"acct","value":"acct-1"},
             {"op":"is","field":"description","value":"payee-merged"},
             \(Self.monthlyDateJSON)]
            """)

        let schedules = try db.fetchPostableSchedules()
        #expect(schedules.first?.payeeId == "payee-target")
    }

    /// LEFT JOIN semantics: a payee value with no payee_mapping row yields a
    /// nil payee (loot-core's pm.targetId is NULL there) — still postable.
    @Test func unmappedPayeeYieldsNilPayeeButStillPostable() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try insertSchedule(db, conditions: """
            [{"op":"is","field":"acct","value":"acct-1"},
             {"op":"is","field":"description","value":"payee-unmapped"},
             \(Self.monthlyDateJSON)]
            """)

        let schedules = try db.fetchPostableSchedules()
        #expect(schedules.count == 1)
        #expect(schedules.first?.payeeId == nil)
    }

    /// extractScheduleConds is two-pass: a `payee` condition beats an EARLIER
    /// `description` one, and `account` beats an earlier `acct`. If array
    /// order won here the closed acct would get picked and the row skipped.
    @Test func payeeAndAccountFieldsWinOverEarlierAliases() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try insertSchedule(db, conditions: """
            [{"op":"is","field":"description","value":"payee-1"},
             {"op":"is","field":"payee","value":"payee-merged"},
             {"op":"is","field":"acct","value":"acct-closed"},
             {"op":"is","field":"account","value":"acct-1"},
             \(Self.monthlyDateJSON)]
            """)

        let schedules = try db.fetchPostableSchedules()
        #expect(schedules.count == 1)
        #expect(schedules.first?.accountId == "acct-1")
        #expect(schedules.first?.payeeId == "payee-target")
    }

    /// The advance write needs base_next_date_ts; a NULL there is a skip,
    /// without poisoning other schedules in the same fetch.
    @Test func skipsNullBaseNextDateTsWithoutAffectingOthers() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try insertSchedule(db, id: "s-nots", localNextDateTs: nil, baseNextDateTs: nil)
        try insertSchedule(db, id: "s-ok")

        let schedules = try db.fetchPostableSchedules()
        #expect(schedules.map(\.id) == ["s-ok"])
    }

    /// A malformed amount value (neither number nor {num1,num2}) degrades to
    /// nil amount — the schedule is still returned, the poster decides.
    @Test func malformedAmountValueYieldsNilAmount() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try insertSchedule(db, conditions: """
            [{"op":"is","field":"acct","value":"acct-1"},
             {"op":"is","field":"amount","value":"fifteen dollars"},
             \(Self.monthlyDateJSON)]
            """)

        let schedules = try db.fetchPostableSchedules()
        #expect(schedules.count == 1)
        #expect(schedules.first?.amount == nil)
    }

    // MARK: - postAmount (JS Math.round parity)

    @Test func postAmountMatchesJSRounding() {
        // JS: Math.round((-3 + -4) / 2) == Math.round(-3.5) == -3 (half toward +∞).
        #expect(ScheduledAmount.range(-3, -4).postAmount == -3)
        #expect(ScheduledAmount.range(-1500, -2500).postAmount == -2000)
        #expect(ScheduledAmount.range(3, 4).postAmount == 4)
        #expect(ScheduledAmount.fixed(-1500).postAmount == -1500)
    }

    // MARK: - Effective next date (loot-core v_schedules CASE)

    @Test func localNextDateWinsWhenTimestampsMatch() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try insertSchedule(
            db,
            localNextDate: 20260701, localNextDateTs: 5_000,
            baseNextDate: 20260801, baseNextDateTs: 5_000
        )

        let schedules = try db.fetchPostableSchedules()
        #expect(schedules.first?.nextDate.yyyymmdd == 20260701)
    }

    @Test func baseNextDateWinsWhenTimestampsDiffer() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try insertSchedule(
            db,
            localNextDate: 20260701, localNextDateTs: 5_000,
            baseNextDate: 20260801, baseNextDateTs: 6_000
        )

        let schedules = try db.fetchPostableSchedules()
        #expect(schedules.first?.nextDate.yyyymmdd == 20260801)
    }

    // MARK: - Silent skips

    @Test func skipsNonPostingCompletedAndTombstonedSchedules() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try insertSchedule(db, id: "s-nopost", postsTransaction: 0)
        try insertSchedule(db, id: "s-done", completed: 1)
        try insertSchedule(db, id: "s-dead", tombstone: 1)
        try insertSchedule(db, id: "s-ok")

        let schedules = try db.fetchPostableSchedules()
        #expect(schedules.map(\.id) == ["s-ok"])
    }

    @Test func skipsClosedAccountAndMissingAccountCondition() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try insertSchedule(db, id: "s-closed", conditions: """
            [{"op":"is","field":"acct","value":"acct-closed"},
             \(Self.monthlyDateJSON)]
            """)
        try insertSchedule(db, id: "s-noacct", conditions: """
            [{"op":"is","field":"description","value":"payee-1"},
             \(Self.monthlyDateJSON)]
            """)

        let schedules = try db.fetchPostableSchedules()
        #expect(schedules.isEmpty)
    }

    @Test func skipsUnparseableRecurrenceAndMissingDateCondition() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try insertSchedule(db, id: "s-badfreq", conditions: """
            [{"op":"is","field":"acct","value":"acct-1"},
             {"op":"is","field":"date","value":{"frequency":"fortnightly","start":"2026-01-15"}}]
            """)
        try insertSchedule(db, id: "s-nodate", conditions: """
            [{"op":"is","field":"acct","value":"acct-1"},
             {"op":"is","field":"description","value":"payee-1"}]
            """)

        let schedules = try db.fetchPostableSchedules()
        #expect(schedules.isEmpty)
    }

    @Test func skipsInvalidEffectiveNextDate() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        // 20260950: month 9 has no day 50 — not a valid DayDate.
        try insertSchedule(db, id: "s-baddate", localNextDate: 20260950, baseNextDate: 20260950)
        try insertSchedule(db, id: "s-nulldate", localNextDate: nil, baseNextDate: nil)

        let schedules = try db.fetchPostableSchedules()
        #expect(schedules.isEmpty)
    }

    @Test func missingScheduleTablesReturnsEmpty() async throws {
        let (db, url) = try makeDatabase(includeScheduleTables: false)
        defer { cleanup(url) }

        let schedules = try db.fetchPostableSchedules()
        #expect(schedules.isEmpty)
    }

    // MARK: - hasTransaction (dedup guard)

    private func insertTransaction(
        _ db: BudgetDatabase, id: String, schedule: String?, date: Int, tombstone: Int = 0
    ) throws {
        try db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, date, amount, schedule, tombstone)
                VALUES (?, 'acct-1', ?, -1500, ?, ?)
                """, arguments: [id, date, schedule, tombstone])
        }
    }

    @Test func hasTransactionFindsExactAndLaterDates() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try insertTransaction(db, id: "t-1", schedule: "sched-1", date: 20260801)

        #expect(try db.hasTransaction(scheduleId: "sched-1", onOrAfter: 20260801))
        #expect(try db.hasTransaction(scheduleId: "sched-1", onOrAfter: 20260715))
    }

    @Test func hasTransactionIgnoresEarlierAndTombstonedMatches() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try insertTransaction(db, id: "t-old", schedule: "sched-1", date: 20260701)
        try insertTransaction(db, id: "t-dead", schedule: "sched-1", date: 20260801, tombstone: 1)
        try insertTransaction(db, id: "t-other", schedule: "sched-2", date: 20260801)

        #expect(try db.hasTransaction(scheduleId: "sched-1", onOrAfter: 20260801) == false)
    }
}
