import XCTest

final class ScheduleRowUITests: XCTestCase {
    @MainActor
    func testRedesignedRowContentsAndRecurrenceAccessibility() {
        let app = XCUIApplication()
        app.launchArguments = ["-showScheduleRowFixture", "-hideDecimalPlaces", "NO"]
        app.launch()

        let row = app.descendants(matching: .any)["scheduleRow.fixture"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        for text in ["Rent", "Status: Upcoming", "~ -", "1,200.00", "Checking", "Recurring", "Oct", "2026"] {
            XCTAssertTrue(row.label.contains(text), "row label missing \(text): \(row.label)")
        }
    }

    @MainActor
    func testRegisterRowOffersPostingAndSkipAndSurfacesFailures() {
        let app = XCUIApplication()
        app.launchArguments = ["-showScheduleRowFixture", "-showUpcomingScheduleFixture"]
        app.launch()
        let row = app.buttons["scheduleRegister.row.fixture"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons["scheduleRegister.post.fixture"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["scheduleRegister.skip.fixture"].exists)
        app.buttons["scheduleRegister.postToday.fixture"].tap()
        XCTAssertTrue(app.alerts["Action Failed"].waitForExistence(timeout: 5))
        app.alerts["Action Failed"].buttons["OK"].tap()
        row.tap()
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit Schedule"].waitForExistence(timeout: 5))
    }
}
