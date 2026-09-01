import XCTest

final class TransactionLongPressSelectUITests: XCTestCase {
    @MainActor
    func testLongPressOpensSelectionModeAndSelectsTheRow() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-hideClearedTransactions", "NO",
            "-transactionDisplayMode", "flat",
        ]
        app.launch()

        app.tabBars.buttons["Accounts"].tap()
        let allAccounts = app.staticTexts["All Accounts"].firstMatch
        XCTAssertTrue(allAccounts.waitForExistence(timeout: 10))
        allAccounts.tap()

        let doneButton = app.buttons["Select"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 10))

        // Transaction rows are the buttons in the list; the first button
        // after the navigation controls is the first demo transaction row.
        let row = app.buttons.element(boundBy: 1)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 0.9)

        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Delete 1 Selected"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Delete 1 Selected"].isEnabled)
    }
}
