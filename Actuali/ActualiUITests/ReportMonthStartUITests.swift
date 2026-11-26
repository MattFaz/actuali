import XCTest

final class ReportMonthStartUITests: XCTestCase {
    @MainActor
    func testMonthStartOpensFromDashboardMenu() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()

        let reports = app.tabBars.buttons["Reports"]
        XCTAssertTrue(reports.waitForExistence(timeout: 10))
        reports.tap()

        let menu = app.buttons["reports.dashboardMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()

        let monthStart = app.buttons["reports.monthStart"]
        XCTAssertTrue(monthStart.waitForExistence(timeout: 5))
        monthStart.tap()

        let done = app.buttons["monthStart.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
    }
}
