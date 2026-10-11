import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreScheduleLoadingTests {
    private func populatedDatabase() async throws -> (BudgetDatabase, URL) {
        let (database, url) = try await makeTestDatabase(TestSchema.core + [
            TestSchema.preferences, TestSchema.rules, TestSchema.schedules, TestSchema.schedulesNextDate,
        ])
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: "ALTER TABLE schedules ADD COLUMN sort_order REAL")
            try db.execute(sql: "INSERT INTO accounts (id, name) VALUES ('a', 'Checking')")
            try db.execute(sql: "INSERT INTO rules (id, conditions, actions) VALUES ('r', ?, '[]')", arguments: [
                #"[{"op":"is","field":"account","value":"a"},{"op":"is","field":"amount","value":-100}]"#,
            ])
            try db.execute(sql: "INSERT INTO schedules (id, rule, name) VALUES ('s', 'r', 'Rent')")
            try db.execute(sql: "INSERT INTO schedules_next_date (id, schedule_id, local_next_date, base_next_date) VALUES ('nd', 's', ?, ?)",
                           arguments: [DayDate.today().yyyymmdd, DayDate.today().yyyymmdd])
        }
        return (database, url)
    }

    @Test(arguments: [false, true])
    func failedLoadDropsSnapshotAndRecoveryClearsError(refresh: Bool) async throws {
        let (database, url) = try await populatedDatabase()
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        await store.loadSchedules()
        #expect(store.schedules.map(\.id) == ["s"])
        #expect(store.scheduleStatuses["s"] == .due)
        #expect(store.schedulesLoaded)
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: "ALTER TABLE schedules_next_date RENAME COLUMN local_next_date TO broken_date")
        }
        if refresh {
            await store.sync()
        } else {
            await store.loadSchedules()
        }
        #expect(store.schedules.isEmpty)
        #expect(store.scheduleStatuses.isEmpty)
        #expect(store.schedulePaymentDates.isEmpty)
        #expect(store.schedulesLoaded)
        #expect(store.scheduleLoadError != nil)
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: "ALTER TABLE schedules_next_date RENAME COLUMN broken_date TO local_next_date")
        }
        if refresh {
            await store.sync()
        } else {
            await store.loadSchedules()
        }
        #expect(store.schedules.map(\.id) == ["s"])
        #expect(store.scheduleLoadError == nil)
    }

    @Test func changingDatabaseClearsAllScheduleState() async throws {
        let (database, url) = try await populatedDatabase()
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        await store.loadSchedules()
        #expect(!store.schedules.isEmpty)
        store.closeDatabaseForTesting()
        #expect(store.schedules.isEmpty)
        #expect(store.scheduleStatuses.isEmpty)
        #expect(store.schedulePaymentDates.isEmpty)
        #expect(!store.schedulesLoaded)
        #expect(store.scheduleLoadError == nil)
        await store.loadSchedules()
        #expect(store.schedulesLoaded)
        #expect(store.schedules.isEmpty)
        #expect(store.scheduleLoadError == nil)
    }
}
