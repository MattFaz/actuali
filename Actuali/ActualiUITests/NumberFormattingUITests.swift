import XCTest

final class NumberFormattingUITests: XCTestCase {
    @MainActor
    func testDisplayNumberFormattingCanBeChanged() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "4"]
        app.launch()

        let displayRow = app.buttons["Display"]
        XCTAssertTrue(displayRow.waitForExistence(timeout: 5), "Display settings row not found")
        displayRow.tap()

        let navigationBar = app.navigationBars["Display"]
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 5), "Display settings screen did not open")

        let picker = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Number Formatting'")
        ).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Number Formatting picker not found")
        picker.tap()

        let selectedFormat = app.buttons["1.000,33"]
        XCTAssertTrue(selectedFormat.waitForExistence(timeout: 5), "Dot-comma format option not found")
        selectedFormat.tap()

        XCTAssertTrue(
            picker.waitForExistence(timeout: 5),
            "Number Formatting picker disappeared after selection"
        )
        XCTAssertTrue(
            picker.label.contains("1.000,33"),
            "Number Formatting picker did not select the dot-comma format"
        )
    }
}
