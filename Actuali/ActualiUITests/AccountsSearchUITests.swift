import XCTest

/// End-to-end coverage for the Accounts search: activation, filtering, clear,
/// no-results handling, and cancellation.
final class AccountsSearchUITests: XCTestCase {
    @MainActor
    func testSearchFiltersClearsAndCancels() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()

        app.tabBars.buttons["Accounts"].tap()

        let chase = app.staticTexts["Chase Checking"].firstMatch
        if !chase.waitForExistence(timeout: 2) {
            let onBudgetHeader = app.buttons["account.group.on-budget"]
            XCTAssertTrue(onBudgetHeader.waitForExistence(timeout: 10))
            onBudgetHeader.tap()
        }
        XCTAssertTrue(chase.waitForExistence(timeout: 10))

        let searchButton = app.buttons["accounts.search"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 10))
        searchButton.tap()

        let searchField = app.textFields["accounts.searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.typeText("vanguard")

        let vanguard = app.staticTexts["Vanguard Brokerage"].firstMatch
        XCTAssertTrue(vanguard.waitForExistence(timeout: 10),
                      "search should find the off-budget account")
        XCTAssertFalse(chase.exists,
                       "search should hide non-matching accounts")

        app.buttons["accounts.searchClear"].tap()
        XCTAssertTrue(chase.waitForExistence(timeout: 10),
                      "clearing the search should restore all accounts")

        searchField.typeText("zzzz")
        let noResults = app.staticTexts["No Results"].firstMatch
        XCTAssertTrue(noResults.waitForExistence(timeout: 10),
                      "a non-matching search should show the no-results state")
        XCTAssertFalse(chase.exists)

        searchButton.tap()
        XCTAssertTrue(chase.waitForExistence(timeout: 10),
                      "cancelling search should restore the full account list")
        XCTAssertFalse(searchField.exists,
                       "cancelling search should remove the search field")
    }
}
