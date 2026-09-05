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

        let selectionModeButton = app.buttons["transactions.selectionMode"]
        XCTAssertTrue(selectionModeButton.waitForExistence(timeout: 10))
        XCTAssertEqual(selectionModeButton.label, "Select")

        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'transactionRow.'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 0.9)

        XCTAssertTrue(selectionModeButton.waitForExistence(timeout: 2))
        XCTAssertEqual(selectionModeButton.label, "Done")
        XCTAssertTrue(app.buttons["Delete 1 Selected"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Delete 1 Selected"].isEnabled)
    }
}
