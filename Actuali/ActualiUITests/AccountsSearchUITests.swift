import XCTest

/// End-to-end coverage for the Accounts search: activation, filtering, clear,
/// no-results handling, and cancellation on both native and fallback search UI.
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

        tapSearch(in: app, customButtonIdentifier: "accounts.search")
        let searchField = activeSearchField(in: app, customFieldIdentifier: "accounts.searchField")
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        typeSearchText("chase", in: searchField)
        XCTAssertTrue(chase.waitForExistence(timeout: 10))
        XCTAssertTrue(header.label.contains("expanded"),
                      "visible search results must be announced as expanded")
        XCTAssertFalse(header.isEnabled,
                       "search forces rows open, so collapse must not be offered")
        XCTAssertFalse(app.staticTexts["All Accounts"].firstMatch.exists)

        cancelSearch(in: app, customButtonIdentifier: "accounts.search")
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

        XCTAssertTrue(searchControl(in: app, customButtonIdentifier: "accounts.search").waitForExistence(timeout: 10),
                      "search action should be available when accounts exist")
        XCTAssertFalse(app.textFields["accounts.searchField"].exists,
                       "the fallback field should stay hidden until search is opened")
        XCTAssertFalse(app.searchFields.firstMatch.exists,
                       "the native search field should stay hidden until the icon is tapped")
        XCTAssertFalse(app.navigationBars["Accounts"].exists,
                       "the Accounts page title must stay hidden")

        tapSearch(in: app, customButtonIdentifier: "accounts.search")
        let searchField = activeSearchField(in: app, customFieldIdentifier: "accounts.searchField")
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        typeSearchText("vanguard", in: searchField)

        let vanguard = app.staticTexts["Vanguard Brokerage"].firstMatch
        XCTAssertTrue(vanguard.waitForExistence(timeout: 10),
                      "search should find the off-budget account")
        XCTAssertFalse(chase.exists,
                       "search should hide non-matching accounts")
        XCTAssertFalse(app.staticTexts["All Accounts"].firstMatch.exists)

        clearSearch(in: app, customClearIdentifier: "accounts.searchClear")
        XCTAssertTrue(chase.waitForExistence(timeout: 10),
                      "clearing the search should restore all accounts")

        XCTAssertTrue(app.staticTexts["All Accounts"].firstMatch.exists)
        typeSearchText("zzzz", in: searchField)
        let noResults = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] 'No Results'"))
            .firstMatch
        XCTAssertTrue(noResults.waitForExistence(timeout: 10),
                      "a non-matching search should show the no-results state")
        XCTAssertFalse(chase.exists)

        cancelSearch(in: app, customButtonIdentifier: "accounts.search")
        XCTAssertTrue(chase.waitForExistence(timeout: 10),
                      "cancelling search should restore the full account list")
        XCTAssertTrue(searchControl(in: app, customButtonIdentifier: "accounts.search").waitForExistence(timeout: 10),
                      "cancelling search should restore the toolbar search action")
        XCTAssertFalse(app.textFields["accounts.searchField"].exists,
                       "cancelling search must hide the fallback field")
        XCTAssertFalse(app.searchFields.firstMatch.exists,
                       "cancelling search must hide the native search field")

        tapSearch(in: app, customButtonIdentifier: "accounts.search")
        let reopenedField = activeSearchField(in: app, customFieldIdentifier: "accounts.searchField")
        XCTAssertTrue(reopenedField.waitForExistence(timeout: 10))
        typeSearchText("chase", in: reopenedField)
        XCTAssertTrue(chase.waitForExistence(timeout: 10),
                      "reopening search must focus the field again")
        cancelSearch(in: app, customButtonIdentifier: "accounts.search")
    }
}
