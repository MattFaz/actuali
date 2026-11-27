import XCTest

final class ReportMonthStartUITests: XCTestCase {
    @MainActor
    func testMonthStartOpensFromDisplaySettings() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()

        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()

        let display = app.buttons["Display"]
        XCTAssertTrue(display.waitForExistence(timeout: 5))
        display.tap()

        let monthStart = app.buttons["displaySettings.monthStart"]
        scrollUntilHittable(monthStart, in: app, maxSwipes: 4, velocity: .slow)
        XCTAssertTrue(monthStart.isHittable)
        monthStart.tap()

        XCTAssertTrue(app.navigationBars["Report Month Start"].waitForExistence(timeout: 5))

        // The adjustment choices are rows on the page, not a menu squeezed
        // beside its label.
        let next = app.buttons["Next Working Day"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Previous Working Day"].exists)
        XCTAssertTrue(app.buttons["Keep Selected Day"].exists)
        next.tap()
        XCTAssertTrue(next.isSelected)
    }
}
