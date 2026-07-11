import Foundation
import Testing
import GRDB
@testable import Actuali

@MainActor
struct BudgetDatabaseDashboardTests {

    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let database = try BudgetDatabase(path: tempURL)
        return (database, tempURL)
    }

    private func insertWidget(
        path: URL,
        id: String,
        type: String,
        x: Int = 0,
        y: Int = 0,
        meta: String? = nil,
        tombstone: Int = 0,
        pageId: String? = nil
    ) throws {
        let queue = try DatabaseQueue(path: path.path)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO dashboard (id, type, x, y, meta, tombstone, dashboard_page_id)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, type, x, y, meta, tombstone, pageId])
        }
    }

    private func insertPage(
        path: URL,
        id: String,
        name: String,
        tombstone: Int = 0
    ) throws {
        let queue = try DatabaseQueue(path: path.path)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO dashboard_pages (id, name, tombstone)
                VALUES (?, ?, ?)
                """, arguments: [id, name, tombstone])
        }
    }

    @Test func returnsEmptyForFreshDatabase() async throws {
        let (database, _) = try makeDatabase()
        let widgets = try await database.fetchWidgets()
        #expect(widgets.isEmpty)
    }

    @Test func returnsParsedWidgets() async throws {
        let (database, path) = try makeDatabase()
        try insertWidget(path: path, id: "a", type: "summary-card",
                         meta: #"{"name":"Spent"}"#)
        try insertWidget(path: path, id: "b", type: "net-worth-card",
                         meta: #"{"name":"Net Worth"}"#)

        let widgets = try await database.fetchWidgets()
        #expect(widgets.count == 2)
        #expect(widgets.contains { $0.displayName == "Spent" })
        #expect(widgets.contains { $0.displayName == "Net Worth" })
    }

    @Test func excludesTombstonedWidgets() async throws {
        let (database, path) = try makeDatabase()
        try insertWidget(path: path, id: "alive", type: "summary-card", meta: "{}")
        try insertWidget(path: path, id: "dead", type: "summary-card", meta: "{}",
                         tombstone: 1)

        let widgets = try await database.fetchWidgets()
        #expect(widgets.count == 1)
        #expect(widgets.first?.id == "alive")
    }

    @Test func returnsInYXOrder() async throws {
        let (database, path) = try makeDatabase()
        try insertWidget(path: path, id: "bottom", type: "summary-card", x: 0, y: 4, meta: "{}")
        try insertWidget(path: path, id: "top-right", type: "summary-card", x: 4, y: 0, meta: "{}")
        try insertWidget(path: path, id: "top-left", type: "summary-card", x: 0, y: 0, meta: "{}")

        let widgets = try await database.fetchWidgets()
        #expect(widgets.map(\.id) == ["top-left", "top-right", "bottom"])
    }

    // The web app treats dashboard pages as separate dashboards and renders
    // only the first live page (ReportsDashboardRouter redirects to
    // dashboardPages[0]). Upstream's multiple-dashboards migration runs
    // per-client and mints a fresh "Main" page id each time, so a synced
    // budget can carry orphaned page ids and full duplicate widget sets
    // (GH: Reports showed every widget twice).
    @Test func showsOnlyFirstLivePageWhenPagesExist() async throws {
        let (database, path) = try makeDatabase()
        try insertPage(path: path, id: "page-main", name: "Main")
        try insertPage(path: path, id: "page-second", name: "Second")
        try insertPage(path: path, id: "page-deleted", name: "Old", tombstone: 1)

        try insertWidget(path: path, id: "main-1", type: "summary-card", y: 2,
                         meta: "{}", pageId: "page-main")
        try insertWidget(path: path, id: "main-0", type: "summary-card", y: 0,
                         meta: "{}", pageId: "page-main")
        try insertWidget(path: path, id: "second-page", type: "summary-card",
                         meta: "{}", pageId: "page-second")
        try insertWidget(path: path, id: "on-deleted-page", type: "summary-card",
                         meta: "{}", pageId: "page-deleted")
        try insertWidget(path: path, id: "orphan", type: "summary-card",
                         meta: "{}", pageId: "page-ghost")
        try insertWidget(path: path, id: "pageless", type: "summary-card",
                         meta: "{}")

        let widgets = try await database.fetchWidgets()
        #expect(widgets.map(\.id) == ["main-0", "main-1"])
    }

    // Budgets from servers that predate multiple dashboards have no page
    // rows; their widgets carry no page id and must still render. Widgets
    // pointing at a page that no longer exists stay hidden, matching the web.
    @Test func fallsBackToPagelessWidgetsWhenNoLivePages() async throws {
        let (database, path) = try makeDatabase()
        try insertPage(path: path, id: "page-deleted", name: "Old", tombstone: 1)

        try insertWidget(path: path, id: "pageless", type: "summary-card", meta: "{}")
        try insertWidget(path: path, id: "orphan", type: "summary-card",
                         meta: "{}", pageId: "page-ghost")

        let widgets = try await database.fetchWidgets()
        #expect(widgets.map(\.id) == ["pageless"])
    }

    @Test func unknownTypeReturnsAsUnsupported() async throws {
        let (database, path) = try makeDatabase()
        try insertWidget(path: path, id: "x", type: "sankey-card", meta: "{}")

        let widgets = try await database.fetchWidgets()
        #expect(widgets.count == 1)
        if case .unsupported(let id, let type) = widgets.first {
            #expect(id == "x")
            #expect(type == "sankey-card")
        } else {
            Issue.record("Expected .unsupported")
        }
    }
}
