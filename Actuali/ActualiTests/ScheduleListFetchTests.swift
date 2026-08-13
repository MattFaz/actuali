
import Foundation
import Testing
import GRDB
@testable import Actuali

/// Pins `fetchSchedules()` and `fetchPaidScheduleIds(for:)`. The list fetch is
/// deliberately more forgiving than the poster's: a schedule with a broken rule
/// or a missing next-date row must still come back, or it becomes unreachable
/// from the phone.
@MainActor
struct ScheduleListFetchTests {
    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")

        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY, name TEXT,
                    offbudget INTEGER DEFAULT 0, closed INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0
                );
                CREATE TABLE payees (
                    id TEXT PRIMARY KEY, name TEXT,
                    transfer_acct TEXT, tombstone INTEGER DEFAULT 0
                );
                CREATE TABLE payee_mapping (id TEXT PRIMARY KEY, targetId TEXT);
                CREATE TABLE categories (
                    id TEXT PRIMARY KEY, name TEXT, tombstone INTEGER DEFAULT 0
                );
                CREATE TABLE category_mapping (id TEXT PRIMARY KEY, transferId TEXT);
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY, isParent INTEGER DEFAULT 0,
                    isChild INTEGER DEFAULT 0, acct TEXT, category TEXT,
                    description TEXT, amount INTEGER, notes TEXT, date INTEGER,
                    imported_description TEXT, transferred_id TEXT,
                    cleared INTEGER DEFAULT 0, reconciled INTEGER DEFAULT 0,
                    sort_order REAL, parent_id TEXT, schedule TEXT,
                    tombstone INTEGER DEFAULT 0
                );
                CREATE TABLE messages_crdt (
                    id INTEGER PRIMARY KEY, timestamp TEXT NOT NULL UNIQUE,
                    dataset TEXT NOT NULL, row TEXT NOT NULL,
                    column TEXT NOT NULL, value BLOB NOT NULL
                );
                CREATE TABLE rules (
                    id TEXT PRIMARY KEY, stage TEXT,
                    conditions_op TEXT DEFAULT 'and', conditions TEXT,
                    actions TEXT, tombstone INTEGER DEFAULT 0
                );
                CREATE TABLE schedules (
                    id TEXT PRIMARY KEY, rule TEXT, active INTEGER DEFAULT 0,
                    completed INTEGER DEFAULT 0, posts_transaction INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0, name TEXT,
                    sort_order REAL, custom_upcoming_length TEXT
                );
                CREATE TABLE schedules_next_date (
                    id TEXT PRIMARY KEY, schedule_id TEXT,
                    local_next_date INTEGER, local_next_date_ts INTEGER,
                    base_next_date INTEGER, base_next_date_ts INTEGER
                );
            """)
            try db.execute(sql: "INSERT INTO accounts (id, name) VALUES ('acct-1', 'Checking')")
            try db.execute(sql: "INSERT INTO payee_mapping (id, targetId) VALUES ('payee-1', 'payee-1')")
            try db.execute(sql: "INSERT INTO payee_mapping (id, targetId) VALUES ('payee-old', 'payee-1')")
        }
        return (try BudgetDatabase(path: tempURL), tempURL)
    }

    /// Inserts a schedule + rule + next-date row. Pass `ruleId: nil` to model a
    /// schedule whose rule went missing.
    private func insertSchedule(
        _ database: BudgetDatabase,
        id: String,
        name: String? = nil,
        conditions: String = """
            [{"op":"is","field":"account","value":"acct-1"},
             {"op":"is","field":"payee","value":"payee-1"},
             {"op":"isapprox","field":"date","value":"2026-08-13"},
             {"op":"isapprox","field":"amount","value":-1250}]
            """,
        actions: String = #"[{"op":"link-schedule","value":"sched-1"}]"#,
        ruleId: String? = "rule-1",
        nextDate: Int? = 20260813,
        postsTransaction: Bool = false,
        completed: Bool = false
    ) throws {
        try database.dbQueueForTesting.write { db in
            if let ruleId {
                try db.execute(sql: """
                    INSERT INTO rules (id, stage, conditions_op, conditions, actions, tombstone)
                    VALUES (?, NULL, 'and', ?, ?, 0)
                    """, arguments: [ruleId, conditions, actions])
            }
            try db.execute(sql: """
                INSERT INTO schedules (id, rule, name, completed, posts_transaction, tombstone)
                VALUES (?, ?, ?, ?, ?, 0)
                """, arguments: [id, ruleId, name, completed ? 1 : 0, postsTransaction ? 1 : 0])
            if let nextDate {
                try db.execute(sql: """
                    INSERT INTO schedules_next_date
                        (id, schedule_id, local_next_date, local_next_date_ts,
                         base_next_date, base_next_date_ts)
                    VALUES (?, ?, ?, 100, ?, 100)
                    """, arguments: ["nd-\(id)", id, nextDate, nextDate])
            }
        }
    }

    @Test func readsEveryFieldOffTheLinkedRule() throws {
        let (database, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        try insertSchedule(database, id: "sched-1", name: "Rent")

        let schedules = try database.fetchSchedules()
        #expect(schedules.count == 1)
        let schedule = try #require(schedules.first)
        #expect(schedule.name == "Rent")
        #expect(schedule.ruleId == "rule-1")
        #expect(schedule.accountId == "acct-1")
        #expect(schedule.payeeId == "payee-1")
        #expect(schedule.amount == .fixed(-1250))
        #expect(schedule.amountOp == .isApprox)
        #expect(schedule.dateOp == "isapprox")
        #expect(schedule.nextDate == DayDate(yyyymmdd: 20260813))
        #expect(schedule.nextDateRowId == "nd-sched-1")
        #expect(schedule.isCustom == false)
        #expect(schedule.isRecurring == false)
    }

    /// Completed and manual schedules are excluded by the poster's fetch but
    /// must appear on the list screen.
    @Test func includesCompletedAndManualSchedules() throws {
        let (database, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        try insertSchedule(database, id: "sched-1", name: "Done", ruleId: "rule-1", completed: true)
        try insertSchedule(database, id: "sched-2", name: "Manual", ruleId: "rule-2")

        #expect(try database.fetchSchedules().count == 2)
        #expect(try database.fetchPostableSchedules().isEmpty)
    }

    @Test func brokenSchedulesStayVisible() throws {
        let (database, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        try insertSchedule(database, id: "sched-1", name: "No rule", ruleId: nil)
        try insertSchedule(database, id: "sched-2", name: "No next date",
                           ruleId: "rule-2", nextDate: nil)

        let schedules = try database.fetchSchedules()
        #expect(schedules.count == 2)
        #expect(schedules.contains { $0.name == "No rule" && $0.ruleId == nil })
        #expect(schedules.contains { $0.name == "No next date" && $0.nextDate == nil })
    }

    @Test func tombstonedSchedulesAreExcluded() throws {
        let (database, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        try insertSchedule(database, id: "sched-1")
        try database.dbQueueForTesting.write { db in
            try db.execute(sql: "UPDATE schedules SET tombstone = 1 WHERE id = 'sched-1'")
        }
        #expect(try database.fetchSchedules().isEmpty)
    }

    @Test func mergedPayeesResolveThroughPayeeMapping() throws {
        let (database, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        try insertSchedule(database, id: "sched-1", conditions: """
            [{"op":"is","field":"account","value":"acct-1"},
             {"op":"is","field":"payee","value":"payee-old"},
             {"op":"isapprox","field":"date","value":"2026-08-13"},
             {"op":"is","field":"amount","value":-500}]
            """)

        let schedule = try #require(try database.fetchSchedules().first)
        #expect(schedule.payeeId == "payee-1")
        #expect(schedule.amountOp == .isExactly)
    }

    @Test func recurringDateConditionIsParsed() throws {
        let (database, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        try insertSchedule(database, id: "sched-1", conditions: """
            [{"op":"is","field":"account","value":"acct-1"},
             {"op":"isapprox","field":"date","value":
               {"frequency":"monthly","start":"2026-01-15","interval":1}},
             {"op":"isbetween","field":"amount","value":{"num1":-1200,"num2":-1000}}]
            """)

        let schedule = try #require(try database.fetchSchedules().first)
        #expect(schedule.isRecurring)
        #expect(schedule.amountOp == .isBetween)
        #expect(schedule.amount == .range(-1200, -1000))
        #expect(schedule.postAmount == -1100)
    }

    @Test func extraConditionsMarkTheScheduleCustom() throws {
        let (database, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        try insertSchedule(database, id: "sched-1", conditions: """
            [{"op":"is","field":"account","value":"acct-1"},
             {"op":"isapprox","field":"date","value":"2026-08-13"},
             {"op":"is","field":"amount","value":-500},
             {"op":"contains","field":"notes","value":"rent"}]
            """)
        #expect(try #require(try database.fetchSchedules().first).isCustom)
    }

    @Test func extraActionsMarkTheScheduleCustom() throws {
        let (database, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        try insertSchedule(database, id: "sched-1", actions: """
            [{"op":"link-schedule","value":"sched-1"},
             {"op":"set","field":"category","value":"cat-1"}]
            """)
        #expect(try #require(try database.fetchSchedules().first).isCustom)
    }

    // MARK: - Paid status

    @Test func paidRespectsEachSchedulesOwnLowerBound() throws {
        let (database, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        // Exact-date schedule: no lookback allowed.
        try insertSchedule(database, id: "sched-exact", conditions: """
            [{"op":"is","field":"account","value":"acct-1"},
             {"op":"is","field":"date","value":"2026-08-13"},
             {"op":"is","field":"amount","value":-500}]
            """, ruleId: "rule-1")
        // Manual approximate schedule: two days of lookback.
        try insertSchedule(database, id: "sched-approx", ruleId: "rule-2")

        try database.dbQueueForTesting.write { db in
            // Two days early — covers the approx schedule only.
            try db.execute(sql: """
                INSERT INTO transactions (id, acct, date, amount, schedule, tombstone)
                VALUES ('t1', 'acct-1', 20260811, -500, 'sched-exact', 0),
                       ('t2', 'acct-1', 20260811, -500, 'sched-approx', 0)
                """)
        }

        let schedules = try database.fetchSchedules()
        let paid = try database.fetchPaidScheduleIds(for: schedules)
        #expect(paid == ["sched-approx"])
    }

    @Test func tombstonedTransactionsDoNotCountAsPaid() throws {
        let (database, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        try insertSchedule(database, id: "sched-1")
        try database.dbQueueForTesting.write { db in
            try db.execute(sql: """
                INSERT INTO transactions (id, acct, date, amount, schedule, tombstone)
                VALUES ('t1', 'acct-1', 20260813, -500, 'sched-1', 1)
                """)
        }
        let schedules = try database.fetchSchedules()
        #expect(try database.fetchPaidScheduleIds(for: schedules).isEmpty)
    }

    @Test func noSchedulesMeansNoQuery() throws {
        let (database, url) = try makeDatabase()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try database.fetchPaidScheduleIds(for: []).isEmpty)
    }
}
