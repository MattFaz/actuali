import XCTest

final class TransactionToolbarOptionsUITests: XCTestCase {

    @MainActor
    func testOptionsExposeAndUpdateTheirSelectedState() throws {
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

        let moreButton = app.navigationBars.buttons["More"]
        XCTAssertTrue(moreButton.waitForExistence(timeout: 10))
        let hideCleared = app.buttons["Hide Cleared Transactions"]
        let groupByDate = app.buttons["Group by Date"]

        moreButton.tap()
        XCTAssertTrue(hideCleared.waitForExistence(timeout: 5))
        XCTAssertFalse(hideCleared.isSelected)
        XCTAssertFalse(groupByDate.isSelected)

        hideCleared.tap()
        moreButton.tap()
        XCTAssertTrue(hideCleared.isSelected)
        hideCleared.tap()

        moreButton.tap()
        groupByDate.tap()
        moreButton.tap()
        XCTAssertTrue(groupByDate.isSelected)
        groupByDate.tap()
    }
}
