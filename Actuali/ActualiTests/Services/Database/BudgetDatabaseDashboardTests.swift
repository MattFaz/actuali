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
        let widgets = try await database.fetchWidgets(pageId: nil)
        #expect(widgets.isEmpty)
    }

    @Test func returnsParsedWidgets() async throws {
        let (database, path) = try makeDatabase()
        try insertWidget(path: path, id: "a", type: "summary-card",
                         meta: #"{"name":"Spent"}"#)
        try insertWidget(path: path, id: "b", type: "net-worth-card",
                         meta: #"{"name":"Net Worth"}"#)

        let widgets = try await database.fetchWidgets(pageId: nil)
        #expect(widgets.count == 2)
        #expect(widgets.contains { $0.displayName == "Spent" })
        #expect(widgets.contains { $0.displayName == "Net Worth" })
    }

    @Test func excludesTombstonedWidgets() async throws {
        let (database, path) = try makeDatabase()
        try insertWidget(path: path, id: "alive", type: "summary-card", meta: "{}")
        try insertWidget(path: path, id: "dead", type: "summary-card", meta: "{}",
                         tombstone: 1)

        let widgets = try await database.fetchWidgets(pageId: nil)
        #expect(widgets.count == 1)
        #expect(widgets.first?.id == "alive")
    }

    @Test func returnsInYXOrder() async throws {
        let (database, path) = try makeDatabase()
        try insertWidget(path: path, id: "bottom", type: "summary-card", x: 0, y: 4, meta: "{}")
        try insertWidget(path: path, id: "top-right", type: "summary-card", x: 4, y: 0, meta: "{}")
        try insertWidget(path: path, id: "top-left", type: "summary-card", x: 0, y: 0, meta: "{}")

        let widgets = try await database.fetchWidgets(pageId: nil)
        #expect(widgets.map(\.id) == ["top-left", "top-right", "bottom"])
    }

    // The web app lists dashboard pages in table order with tombstoned rows
    // filtered (AQL `q('dashboard_pages').select('*')`); a null name renders
    // as an empty string upstream.
    @Test func fetchDashboardPagesReturnsLivePagesInInsertionOrder() async throws {
        let (database, path) = try makeDatabase()
        try insertPage(path: path, id: "page-main", name: "Main")
        try insertPage(path: path, id: "page-deleted", name: "Old", tombstone: 1)
        try insertPage(path: path, id: "page-second", name: "Second")

        let pages = try await database.fetchDashboardPages()
        #expect(pages.map(\.id) == ["page-main", "page-second"])
        #expect(pages.map(\.name) == ["Main", "Second"])
    }

    @Test func fetchDashboardPagesIsEmptyForFreshDatabase() async throws {
        let (database, _) = try makeDatabase()
        let pages = try await database.fetchDashboardPages()
        #expect(pages.isEmpty)
    }

    // Each dashboard page is a separate dashboard (GH #120: multiple
    // dashboards were merged into one). Fetching a page must return only
    // that page's live widgets, in reading order (y, then x) — never
    // widgets from other pages, deleted pages, orphaned page ids, or
    // pageless rows.
    @Test func fetchWidgetsForPageFiltersToThatPageInYXOrder() async throws {
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

        let mainWidgets = try await database.fetchWidgets(pageId: "page-main")
        #expect(mainWidgets.map(\.id) == ["main-0", "main-1"])

        let secondWidgets = try await database.fetchWidgets(pageId: "page-second")
        #expect(secondWidgets.map(\.id) == ["second-page"])
    }

    // Budgets from servers that predate multiple dashboards have no page
    // rows; their widgets carry no page id and must still render. Widgets
    // pointing at a page that no longer exists stay hidden, matching the web.
    @Test func nilPageIdReturnsOnlyPagelessWidgets() async throws {
        let (database, path) = try makeDatabase()
        try insertPage(path: path, id: "page-deleted", name: "Old", tombstone: 1)

        try insertWidget(path: path, id: "pageless", type: "summary-card", meta: "{}")
        try insertWidget(path: path, id: "orphan", type: "summary-card",
                         meta: "{}", pageId: "page-ghost")

        let widgets = try await database.fetchWidgets(pageId: nil)
        #expect(widgets.map(\.id) == ["pageless"])
    }

    @Test func unknownTypeReturnsAsUnsupported() async throws {
        let (database, path) = try makeDatabase()
        try insertWidget(path: path, id: "x", type: "future-card", meta: "{}")

        let widgets = try await database.fetchWidgets(pageId: nil)
        #expect(widgets.count == 1)
        if case .unsupported(let id, let type) = widgets.first {
            #expect(id == "x")
            #expect(type == "future-card")
        } else {
            Issue.record("Expected .unsupported")
        }
    }
}

// Resolution of which dashboard page the Reports tab shows: a still-live
// explicit selection wins, then the dashboard configured in Settings, then the
// first live page (matching the web's ReportsDashboardRouter redirect to
// dashboardPages[0]), otherwise nil so the pre-pages pageless fallback applies.
struct ReportsPageSelectionTests {

    private let pages = [
        DashboardPage(id: "page-main", name: "Main"),
        DashboardPage(id: "page-second", name: "Second")
    ]

    @Test func keepsSelectionWhenStillLive() {
        #expect(ReportsTabView.resolvePageId(selected: "page-second", pages: pages) == "page-second")
    }

    @Test func fallsBackToFirstPageWhenSelectionGone() {
        #expect(ReportsTabView.resolvePageId(selected: "page-deleted", pages: pages) == "page-main")
    }

    @Test func defaultsToFirstPageWhenNothingSelected() {
        #expect(ReportsTabView.resolvePageId(selected: nil, pages: pages) == "page-main")
    }

    @Test func isNilWhenNoLivePages() {
        #expect(ReportsTabView.resolvePageId(selected: "anything", pages: []) == nil)
    }

    @Test func opensConfiguredDefaultWhenNothingSelected() {
        #expect(ReportsTabView.resolvePageId(
            selected: nil,
            configuredDefault: "page-second",
            pages: pages
        ) == "page-second")
    }

    // A live in-session selection is a deliberate switch, so it outranks the
    // setting until the tab is rebuilt.
    @Test func selectionOutranksConfiguredDefault() {
        #expect(ReportsTabView.resolvePageId(
            selected: "page-main",
            configuredDefault: "page-second",
            pages: pages
        ) == "page-main")
    }

    @Test func ignoresConfiguredDefaultForDeletedPage() {
        #expect(ReportsTabView.resolvePageId(
            selected: nil,
            configuredDefault: "page-deleted",
            pages: pages
        ) == "page-main")
    }

    @Test func ignoresConfiguredDefaultWhenNoLivePages() {
        #expect(ReportsTabView.resolvePageId(
            selected: nil,
            configuredDefault: "page-main",
            pages: []
        ) == nil)
    }

    @Test func widgetRevisionBumpsWhenMetaChangesUnderSameId() {
        let before: [DashboardWidget] = [
            .formula(id: "w1", meta: FormulaMeta(
                name: "Net", formula: #"=QUERY("a")"#, queries: nil))
        ]
        let after: [DashboardWidget] = [
            .formula(id: "w1", meta: FormulaMeta(
                name: "Net", formula: #"=QUERY("b")"#, queries: nil))
        ]

        #expect(ReportsTabView.widgetsRevision(0, old: before, new: before) == 0)
        #expect(ReportsTabView.widgetsRevision(0, old: before, new: after) == 1)
    }
}
