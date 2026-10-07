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
        app.launchArguments = ["-showScheduleRowFixture", "-showUpcomingScheduleFixture", "-resetScheduleRegisterPreferences"]
        app.launch()
        let row = app.buttons["scheduleRegister.row.fixture"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons["scheduleRegister.post.fixture"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["scheduleRegister.skip.fixture"].exists)
        app.buttons["scheduleRegister.postToday.fixture"].firstMatch.tap()
        XCTAssertTrue(app.alerts["Action Failed"].waitForExistence(timeout: 5))
        app.alerts["Action Failed"].buttons["OK"].tap()
        row.tap()
        app.buttons["scheduleRegister.edit.fixture"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Edit Schedule"].waitForExistence(timeout: 5))
        app.buttons["scheduleRegister.cancelEdit"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    @MainActor
    func testUpcomingSchedulesCanBeCollapsedAndHiddenAndRememberBothSettings() {
        let app = XCUIApplication()
        let fixtureArguments = ["-showScheduleRowFixture", "-showUpcomingScheduleFixture"]
        app.launchArguments = fixtureArguments + ["-resetScheduleRegisterPreferences"]
        app.launch()
        let row = app.buttons["scheduleRegister.row.fixture"]
        let header = app.buttons["scheduleRegister.expansion"]
        let visibility = app.descendants(matching: .any)["scheduleRegister.visibility"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        header.tap()
        XCTAssertTrue(header.exists)
        XCTAssertFalse(row.exists)
        XCTAssertEqual(header.value as? String, "collapsed")

        app.terminate()
        app.launchArguments = fixtureArguments
        app.launch()
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertFalse(row.exists)
        visibility.tap()
        XCTAssertFalse(header.exists)
        XCTAssertFalse(row.exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(visibility.waitForExistence(timeout: 5))
        XCTAssertFalse(header.exists)
        visibility.tap()
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertFalse(row.exists)
        header.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }
}
