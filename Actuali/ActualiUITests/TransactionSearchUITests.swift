import XCTest

/// End-to-end coverage for GH #65: the All Accounts search queries the
/// database (not just the loaded page), shows the no-match state, and restores
/// results after clearing or cancelling search.
final class TransactionSearchUITests: XCTestCase {
    @MainActor
    func testSearchFindsPayeeShowsNoMatchAndRestores() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-resetStatusFilterState"]
        app.launch()

        app.tabBars.buttons["Accounts"].tap()
        let allAccounts = app.staticTexts["All Accounts"].firstMatch
        XCTAssertTrue(allAccounts.waitForExistence(timeout: 10))
        allAccounts.tap()

        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10),
                      "All Accounts should render register rows after the first page loads")

        let customField = app.textFields["transactions.searchField"]
        XCTAssertFalse(customField.exists,
                       "the fallback search field should stay hidden until search is opened")

        tapSearch(in: app, customButtonIdentifier: "transactions.search")
        let searchField = activeSearchField(in: app, customFieldIdentifier: "transactions.searchField")
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        typeSearchText("netflix", in: searchField)

        let netflixRow = app.staticTexts["Netflix"].firstMatch
        XCTAssertTrue(netflixRow.waitForExistence(timeout: 10),
                      "search should surface Netflix transactions")

        // Append garbage -> no matches -> the empty state must render.
        typeSearchText("zzz", in: searchField)
        let noResults = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] 'No Results'"))
            .firstMatch
        XCTAssertTrue(noResults.waitForExistence(timeout: 10),
                      "no-match search should show the No Results state")
        XCTAssertFalse(netflixRow.exists)

        clearSearch(in: app, customClearIdentifier: "transactions.searchClear")
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10),
                      "clearing the search should restore the transaction list")
        XCTAssertFalse(noResults.exists)

        // Cancelling must drop the query, not just hide the field: start from
        // a no-match state so a leftover filter would keep No Results on screen.
        let restoredSearchField = activeSearchField(in: app, customFieldIdentifier: "transactions.searchField")
        typeSearchText("zzzz", in: restoredSearchField)
        XCTAssertTrue(noResults.waitForExistence(timeout: 10))
        cancelSearch(in: app, customButtonIdentifier: "transactions.search")
        XCTAssertTrue(noResults.waitForNonExistence(timeout: 10),
                      "cancelling search should clear the filter and restore results")
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor
    func testIndividualAccountSearchOpensOnDemand() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()

        app.tabBars.buttons["Accounts"].tap()

        // Expand the budget section and any nested account group that hides
        // Chase Checking; avoid racing a collapsed row during initial rendering.
        let budgetHeader = app.buttons["account.group.on-budget"]
        XCTAssertTrue(budgetHeader.waitForExistence(timeout: 10))
        if budgetHeader.label.localizedCaseInsensitiveContains("collapsed") {
            budgetHeader.tap()
        }

        let chase = app.staticTexts["Chase Checking"].firstMatch
        for _ in 0..<6 {
            if chase.waitForExistence(timeout: 1) {
                break
            }

            let collapsedGroup = app.buttons.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
                    "account.subgroup.",
                    "collapsed"
                )
            ).firstMatch
            guard collapsedGroup.waitForExistence(timeout: 1) else { break }
            collapsedGroup.tap()
        }
        XCTAssertTrue(chase.waitForExistence(timeout: 15),
                      "Chase Checking should appear after its account groups are expanded")
        chase.tap()

        tapSearch(in: app, customButtonIdentifier: "accountDetails.search")
        let searchField = activeSearchField(in: app, customFieldIdentifier: "accountDetails.searchField")
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()
        cancelSearch(in: app, customButtonIdentifier: "accountDetails.search")
        // The native field animates away, so wait rather than sample.
        XCTAssertTrue(app.textFields["accountDetails.searchField"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.searchFields.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10),
                      "cancelling search should restore the account transactions")
    }
}
