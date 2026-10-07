import XCTest

/// End-to-end coverage for the Accounts search: activation, filtering, clear,
/// no-results handling, and cancellation.
final class AccountsSearchUITests: XCTestCase {
    @MainActor
    func testSearchTemporarilyExpandsCollapsedSection() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()
        app.tabBars.buttons["Accounts"].tap()

        let header = app.buttons["account.group.on-budget"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        let chase = app.staticTexts["Chase Checking"].firstMatch
        if !chase.exists {
            header.tap()
        }
        XCTAssertTrue(chase.waitForExistence(timeout: 10))
        header.tap()
        XCTAssertFalse(chase.exists)

        app.buttons["accounts.search"].tap()
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.typeText("chase")
        XCTAssertTrue(chase.waitForExistence(timeout: 10))
        XCTAssertTrue(header.label.contains("expanded"),
                      "visible search results must be announced as expanded")
        XCTAssertFalse(header.isEnabled,
                       "search forces rows open, so collapse must not be offered")
        XCTAssertFalse(app.staticTexts["All Accounts"].firstMatch.exists)

        app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Close"])).firstMatch.tap()
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        XCTAssertTrue(header.label.contains("collapsed"))
        XCTAssertTrue(header.isEnabled)
        XCTAssertFalse(chase.exists,
                       "cancelling search must restore the saved collapsed state")
        header.tap()
        XCTAssertTrue(chase.waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Accounts"].exists,
                      "the Accounts page must have the title requested in #641")
    }

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

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.typeText("vanguard")

        let vanguard = app.staticTexts["Vanguard Brokerage"].firstMatch
        XCTAssertTrue(vanguard.waitForExistence(timeout: 10),
                      "search should find the off-budget account")
        XCTAssertFalse(chase.exists,
                       "search should hide non-matching accounts")
        XCTAssertFalse(app.staticTexts["All Accounts"].firstMatch.exists)

        searchField.buttons["Clear text"].tap()
        XCTAssertTrue(chase.waitForExistence(timeout: 10),
                      "clearing the search should restore all accounts")

        XCTAssertTrue(app.staticTexts["All Accounts"].firstMatch.exists)
        searchField.typeText("zzzz")
        let noResults = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] 'No Results'"))
            .firstMatch
        XCTAssertTrue(noResults.waitForExistence(timeout: 10),
                      "a non-matching search should show the no-results state")
        XCTAssertFalse(chase.exists)

        app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Close"])).firstMatch.tap()
        XCTAssertTrue(chase.waitForExistence(timeout: 10),
                      "cancelling search should restore the full account list")
        XCTAssertTrue(searchButton.waitForExistence(timeout: 10),
                      "cancelling search should restore the toolbar search action")
    }
}
