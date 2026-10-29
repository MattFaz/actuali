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
        typeSearchText("netflix", in: searchField, app: app)

        let netflixRow = app.staticTexts["Netflix"].firstMatch
        XCTAssertTrue(netflixRow.waitForExistence(timeout: 10),
                      "search should surface Netflix transactions")

        // Append garbage -> no matches -> the empty state must render.
        typeSearchText("zzz", in: searchField, app: app)
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

        // Reopening and cancelling must remove the query and restore results.
        let restoredSearchField = activeSearchField(in: app, customFieldIdentifier: "transactions.searchField")
        typeSearchText("netflix", in: restoredSearchField, app: app)
        cancelSearch(in: app, customButtonIdentifier: "transactions.search")
        XCTAssertFalse(noResults.exists,
                       "cancelling search should clear the filter and restore results")
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
    }

    @MainActor
    private func typeSearchText(_ text: String, in field: XCUIElement, app: XCUIApplication) {
        func waitForFocus(_ timeout: TimeInterval) -> Bool {
            let focused = NSPredicate(format: "hasKeyboardFocus == true")
            let expectation = XCTNSPredicateExpectation(predicate: focused, object: field)
            return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
        }

        // Native search may already be focused by the system after expansion.
        if !waitForFocus(2) {
            field.tap()
            if !waitForFocus(3) {
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
        }
        XCTAssertTrue(waitForFocus(5), "the search field should have keyboard focus before typing")
        field.typeText(text)
    }

    @MainActor
    private func tapSearch(in app: XCUIApplication, customButtonIdentifier: String) {
        let customButton = app.buttons[customButtonIdentifier]
        if customButton.waitForExistence(timeout: 1) {
            customButton.tap()
            return
        }

        // On iOS 26+, SwiftUI owns the minimized toolbar search affordance.
        let nativeSearchControl = app.navigationBars.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Search"))
            .firstMatch
        XCTAssertTrue(nativeSearchControl.waitForExistence(timeout: 10),
                      "the native minimized search control should be visible")
        nativeSearchControl.tap()
    }

    @MainActor
    private func activeSearchField(in app: XCUIApplication, customFieldIdentifier: String) -> XCUIElement {
        let customField = app.textFields[customFieldIdentifier]
        if customField.exists {
            return customField
        }
        return app.searchFields.firstMatch
    }

    @MainActor
    private func clearSearch(in app: XCUIApplication, customClearIdentifier: String) {
        let customClearButton = app.buttons[customClearIdentifier]
        if customClearButton.waitForExistence(timeout: 1) {
            customClearButton.tap()
            return
        }

        let nativeClearButton = app.navigationBars.descendants(matching: .button)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Clear"))
            .firstMatch
        XCTAssertTrue(nativeClearButton.waitForExistence(timeout: 10),
                      "the native search field should expose a clear control")
        nativeClearButton.tap()
    }

    @MainActor
    private func cancelSearch(in app: XCUIApplication, customButtonIdentifier: String) {
        let cancelButton = app.navigationBars.descendants(matching: .button)
            .matching(NSPredicate(format: "label CONTAINS[c] 'Cancel' OR label == 'Close'"))
            .firstMatch
        if cancelButton.waitForExistence(timeout: 1) {
            cancelButton.tap()
            return
        }

        let customButton = app.buttons[customButtonIdentifier]
        XCTAssertTrue(customButton.waitForExistence(timeout: 10),
                      "the fallback search toggle should remain available")
        customButton.tap()
    }
}
