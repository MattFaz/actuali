import XCTest

final class ScheduleRowUITests: XCTestCase {
    @MainActor
    func testRedesignedRowContentsAndRecurrenceAccessibility() {
        let app = XCUIApplication()
        app.launchArguments = ["-showScheduleRowFixture"]
        app.launch()

        let row = app.descendants(matching: .any)["scheduleRow.fixture"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        for text in ["Rent", "Status: Upcoming", "~ -", "1,200.00", "Checking", "Recurring", "Oct", "2026"] {
            XCTAssertTrue(row.label.contains(text), "row label missing \(text): \(row.label)")
        }
    }
}
