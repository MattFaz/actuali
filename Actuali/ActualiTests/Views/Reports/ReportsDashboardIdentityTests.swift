import Testing
@testable import Actuali

struct ReportsDashboardIdentityTests {
    @Test func pageRenameKeepsComputedCards() {
        let widgets: [DashboardWidget] = [.summary(id: "s", meta: nil)]
        #expect(!ReportsTabView.dashboardIdentityChanged(loadedWidgets: widgets, fetchedWidgets: widgets,
                                                         loadedPageId: "p", fetchedPageId: "p"))
    }

    @Test func widgetMetaEditRecreatesCardsOnSamePage() {
        let meta = SummaryMeta(name: "Changed", timeFrame: nil, conditions: nil, conditionsOp: nil, content: nil)
        #expect(ReportsTabView.dashboardIdentityChanged(loadedWidgets: [.summary(id: "s", meta: nil)],
                                                        fetchedWidgets: [.summary(id: "s", meta: meta)],
                                                        loadedPageId: "p", fetchedPageId: "p"))
    }

    @Test func pageSwitchRecreatesCardsEvenWithEqualWidgets() {
        let widgets: [DashboardWidget] = [.summary(id: "s", meta: nil)]
        #expect(ReportsTabView.dashboardIdentityChanged(loadedWidgets: widgets, fetchedWidgets: widgets,
                                                        loadedPageId: "p", fetchedPageId: "q"))
    }
}
