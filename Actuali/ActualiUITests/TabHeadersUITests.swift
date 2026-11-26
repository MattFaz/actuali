import XCTest

final class TabHeadersUITests: XCTestCase {
    @MainActor
    func testReportsAndMoreHaveNoNavigationHeader() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "3"]
        app.launch()

        XCTAssertTrue(app.buttons["Switch dashboard"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars.firstMatch.exists)

        app.tabBars.buttons["More"].tap()
        let connection = app.buttons["Connection & Data"]
        XCTAssertTrue(connection.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Settings"].exists)
        XCTAssertFalse(app.navigationBars.firstMatch.exists)

        connection.tap()
        let navigationBar = app.navigationBars["Connection & Data"]
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 5))
        XCTAssertTrue(navigationBar.buttons.firstMatch.isHittable)
        navigationBar.buttons.firstMatch.tap()
        XCTAssertTrue(connection.waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars.firstMatch.exists)
    }
}
