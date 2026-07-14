import XCTest

/// End-to-end coverage for GH #65: the All Accounts search queries the
/// database (not the loaded page), the no-match state renders, and clearing
/// the search restores the paged list.
final class TransactionSearchUITests: XCTestCase {

    @MainActor
    func testSearchFindsPayeeShowsNoMatchAndRestores() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()

        app.tabBars.buttons["Accounts"].tap()
        let allAccounts = app.staticTexts["All Accounts"].firstMatch
        XCTAssertTrue(allAccounts.waitForExistence(timeout: 10))
        allAccounts.tap()

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()
        searchField.typeText("netflix")

        // The demo budget has Netflix transactions; the DB-backed search
        // must surface them (case-insensitively) past the debounce.
        let netflixRow = app.staticTexts["Netflix"].firstMatch
        XCTAssertTrue(netflixRow.waitForExistence(timeout: 10),
                      "search should surface Netflix transactions")

        // Append garbage -> no matches -> the empty state must render.
        searchField.typeText("zzz")
        let noResults = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] 'No Results'"))
            .firstMatch
        XCTAssertTrue(noResults.waitForExistence(timeout: 10),
                      "no-match search should show the No Results state")
        XCTAssertFalse(netflixRow.exists)

        // Clearing the query restores the unfiltered paged list.
        searchField.buttons["Clear text"].tap()
        XCTAssertTrue(netflixRow.waitForExistence(timeout: 10),
                      "clearing the search should restore the transaction list")
    }
}
