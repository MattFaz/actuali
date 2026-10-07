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
        let searchField = app.textFields["accounts.searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.typeText("chase")
        XCTAssertTrue(chase.waitForExistence(timeout: 10))
        XCTAssertTrue(header.label.contains("expanded"),
                      "visible search results must be announced as expanded")
        XCTAssertFalse(header.isEnabled,
                       "search forces rows open, so collapse must not be offered")
        XCTAssertFalse(app.staticTexts["All Accounts"].firstMatch.exists)

        app.buttons["accounts.search"].tap()
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        XCTAssertTrue(header.label.contains("collapsed"))
        XCTAssertTrue(header.isEnabled)
        XCTAssertFalse(chase.exists,
                       "cancelling search must restore the saved collapsed state")
        header.tap()
        XCTAssertTrue(chase.waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["Accounts"].exists,
                       "the Accounts page title must stay hidden")
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
        XCTAssertFalse(app.textFields["accounts.searchField"].exists,
                       "the search field must stay hidden until the icon is tapped")
        XCTAssertFalse(app.searchFields.firstMatch.exists,
                       "there must be no idle native search bar")
        XCTAssertFalse(app.navigationBars["Accounts"].exists,
                       "the Accounts page title must stay hidden")
        searchButton.tap()

        let searchField = app.textFields["accounts.searchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.typeText("vanguard")

        let vanguard = app.staticTexts["Vanguard Brokerage"].firstMatch
        XCTAssertTrue(vanguard.waitForExistence(timeout: 10),
                      "search should find the off-budget account")
        XCTAssertFalse(chase.exists,
                       "search should hide non-matching accounts")
        XCTAssertFalse(app.staticTexts["All Accounts"].firstMatch.exists)

        app.buttons["accounts.searchClear"].tap()
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

        app.buttons["accounts.search"].tap()
        XCTAssertTrue(chase.waitForExistence(timeout: 10),
                      "cancelling search should restore the full account list")
        XCTAssertTrue(searchButton.waitForExistence(timeout: 10),
                      "cancelling search should restore the toolbar search action")
        XCTAssertFalse(searchField.exists,
                       "cancelling search must hide the field again")
        searchButton.tap()
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.typeText("chase")
        XCTAssertTrue(chase.waitForExistence(timeout: 10),
                      "reopening search must focus the field again")
        searchButton.tap()
    }
}
