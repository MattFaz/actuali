import XCTest

final class TransactionToolbarOptionsUITests: XCTestCase {
    @MainActor
    func testOptionsExposeAndUpdateTheirSelectedState() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-transactionDisplayMode", "flat",
        ]
        app.launch()

        app.tabBars.buttons["Accounts"].tap()
        let allAccounts = app.staticTexts["All Accounts"].firstMatch
        XCTAssertTrue(allAccounts.waitForExistence(timeout: 10))
        allAccounts.tap()

        let moreButton = app.navigationBars.buttons["More"]
        XCTAssertTrue(moreButton.waitForExistence(timeout: 10))
        let groupByDate = app.buttons["Group by Date"]

        moreButton.tap()
        XCTAssertTrue(groupByDate.waitForExistence(timeout: 5))
        XCTAssertFalse(groupByDate.isSelected)

        groupByDate.tap()
        moreButton.tap()
        XCTAssertTrue(groupByDate.isSelected)
        groupByDate.tap()
    }
}
