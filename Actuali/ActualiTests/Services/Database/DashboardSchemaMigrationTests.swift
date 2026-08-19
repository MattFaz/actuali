import Foundation
import Testing
import GRDB
@testable import Actuali

@MainActor
struct DashboardSchemaMigrationTests {

    private func makeDatabasePath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
    }

    @Test func createsDashboardTableOnFirstInit() throws {
        let path = makeDatabasePath()
        _ = try BudgetDatabase(path: path)

        let queue = try DatabaseQueue(path: path.path)
        try queue.read { db in
            let dashboardExists = try db.tableExists("dashboard")
            let customReportsExists = try db.tableExists("custom_reports")
            #expect(dashboardExists)
            #expect(customReportsExists)
        }
    }

    @Test func crdtMessageForDashboardLandsInTable() throws {
        let path = makeDatabasePath()
        // messages_crdt normally arrives with the imported budget file zip.
        // Create it explicitly for the test fixture.
        let fixtureQueue = try DatabaseQueue(path: path.path)
        try fixtureQueue.write { db in
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
        let database = try BudgetDatabase(path: path)

        let timestamp = HLCTimestamp(
            millis: 1_700_000_000_000,
            counter: 0,
            node: "test000000000000"
        )
        let messages = [
            CRDTMessage(
                timestamp: timestamp,
                dataset: "dashboard",
                row: "widget-1",
                column: "type",
                value: "S:net-worth-card"
            ),
            CRDTMessage(
                timestamp: timestamp,
                dataset: "dashboard",
                row: "widget-1",
                column: "meta",
                value: "S:{\"name\":\"My Net Worth\"}"
            )
        ]

        _ = try database.insertMessages(messages)
        try database.applyMessages(messages)

        let queue = try DatabaseQueue(path: path.path)
        try queue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT type, meta FROM dashboard WHERE id = ?",
                arguments: ["widget-1"]
            )
            #expect(row != nil)
            #expect((row?["type"] as String?) == "net-worth-card")
            #expect((row?["meta"] as String?)?.contains("My Net Worth") == true)
        }
    }

    @Test func createsDashboardPagesTableOnFirstInit() throws {
        let path = makeDatabasePath()
        _ = try BudgetDatabase(path: path)

        let queue = try DatabaseQueue(path: path.path)
        try queue.read { db in
            #expect(try db.tableExists("dashboard_pages"))
            let columns = Set(try db.columns(in: "dashboard_pages").map(\.name))
            #expect(columns.isSuperset(of: ["id", "name", "tombstone"]))
        }
    }

    // A budget file from a pre-multiple-dashboards server ships a dashboard
    // table without dashboard_page_id. CREATE IF NOT EXISTS won't touch it,
    // so the column must arrive via the upstream ALTER migration — otherwise
    // page-assignment CRDT messages are skipped and the local dashboard
    // diverges from the server.
    @Test func addsDashboardPageIdToLegacyDashboardTable() throws {
        let path = makeDatabasePath()
        let fixtureQueue = try DatabaseQueue(path: path.path)
        try fixtureQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE dashboard (
                    id TEXT PRIMARY KEY,
                    type TEXT,
                    x INTEGER DEFAULT 0,
                    y INTEGER DEFAULT 0,
                    width INTEGER DEFAULT 4,
                    height INTEGER DEFAULT 2,
                    meta TEXT,
                    tombstone INTEGER NOT NULL DEFAULT 0
                )
            """)
        }
        _ = try BudgetDatabase(path: path)

        let queue = try DatabaseQueue(path: path.path)
        try queue.read { db in
            let columns = Set(try db.columns(in: "dashboard").map(\.name))
            #expect(columns.contains("dashboard_page_id"))
        }
    }

    @Test func migrationIsIdempotent() throws {
        let path = makeDatabasePath()
        _ = try BudgetDatabase(path: path)
        _ = try BudgetDatabase(path: path)
    }

    @Test func createsCustomReportsTable() throws {
        let path = makeDatabasePath()
        _ = try BudgetDatabase(path: path)

        let queue = try DatabaseQueue(path: path.path)
        try queue.read { db in
            let exists = try db.tableExists("custom_reports")
            #expect(exists)
        }
    }
}
