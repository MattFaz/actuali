import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct DashboardSchemaMigrationTests {
    @Test func createsDashboardTableOnFirstInit() async throws {
        let (_, path) = try await makeTestDatabase()

        let queue = try DatabaseQueue(path: path.path)
        try await queue.read { db in
            let dashboardExists = try db.tableExists("dashboard")
            let customReportsExists = try db.tableExists("custom_reports")
            #expect(dashboardExists)
            #expect(customReportsExists)
        }
    }

    @Test func crdtMessageForDashboardLandsInTable() async throws {
        // messages_crdt normally arrives with the imported budget file zip.
        let (database, path) = try await makeTestDatabase(TestSchema.messagesCrdt)

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
            ),
        ]

        _ = try database.insertMessages(messages)
        try database.applyMessages(messages)

        let queue = try DatabaseQueue(path: path.path)
        try await queue.read { db in
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

    @Test func createsDashboardPagesTableOnFirstInit() async throws {
        let (_, path) = try await makeTestDatabase()

        let queue = try DatabaseQueue(path: path.path)
        try await queue.read { db in
            #expect(try db.tableExists("dashboard_pages"))
            let columns = try Set(db.columns(in: "dashboard_pages").map(\.name))
            #expect(columns.isSuperset(of: ["id", "name", "tombstone"]))
        }
    }

    /// A budget file from a pre-multiple-dashboards server ships a dashboard
    /// table without dashboard_page_id. CREATE IF NOT EXISTS won't touch it,
    /// so the column must arrive via the upstream ALTER migration — otherwise
    /// page-assignment CRDT messages are skipped and the local dashboard
    /// diverges from the server.
    @Test func addsDashboardPageIdToLegacyDashboardTable() async throws {
        let (_, path) = try await makeTestDatabase("""
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

        let queue = try DatabaseQueue(path: path.path)
        try await queue.read { db in
            let columns = try Set(db.columns(in: "dashboard").map(\.name))
            #expect(columns.contains("dashboard_page_id"))
        }
    }

    @Test func migrationIsIdempotent() async throws {
        let (_, path) = try await makeTestDatabase()
        _ = try BudgetDatabase(path: path)
    }

    @Test func createsCustomReportsTable() async throws {
        let (_, path) = try await makeTestDatabase()

        let queue = try DatabaseQueue(path: path.path)
        try await queue.read { db in
            let exists = try db.tableExists("custom_reports")
            #expect(exists)
        }
    }
}
