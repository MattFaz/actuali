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

        tapSearch(in: app)
        let searchField = activeSearchField(in: app)
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        typeSearchText("chase", in: searchField, app: app)
        XCTAssertTrue(chase.waitForExistence(timeout: 10))
        XCTAssertTrue(header.label.contains("expanded"),
                      "visible search results must be announced as expanded")
        XCTAssertFalse(header.isEnabled,
                       "search forces rows open, so collapse must not be offered")
        XCTAssertFalse(app.staticTexts["All Accounts"].firstMatch.exists)

        cancelSearch(in: app)
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

        XCTAssertTrue(searchControl(in: app).waitForExistence(timeout: 10),
                      "search action should be available when accounts exist")
        XCTAssertFalse(app.textFields["accounts.searchField"].exists,
                       "the fallback field should stay hidden until search is opened")
        XCTAssertFalse(app.searchFields.firstMatch.exists,
                       "the native search field should stay hidden until the icon is tapped")
        XCTAssertFalse(app.navigationBars["Accounts"].exists,
                       "the Accounts page title must stay hidden")

        tapSearch(in: app)
        let searchField = activeSearchField(in: app)
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        typeSearchText("vanguard", in: searchField, app: app)

        let vanguard = app.staticTexts["Vanguard Brokerage"].firstMatch
        XCTAssertTrue(vanguard.waitForExistence(timeout: 10),
                      "search should find the off-budget account")
        XCTAssertFalse(chase.exists,
                       "search should hide non-matching accounts")
        XCTAssertFalse(app.staticTexts["All Accounts"].firstMatch.exists)

        clearSearch(in: app)
        XCTAssertTrue(chase.waitForExistence(timeout: 10),
                      "clearing the search should restore all accounts")

        XCTAssertTrue(app.staticTexts["All Accounts"].firstMatch.exists)
        typeSearchText("zzzz", in: searchField, app: app)
        let noResults = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS[c] 'No Results'"))
            .firstMatch
        XCTAssertTrue(noResults.waitForExistence(timeout: 10),
                      "a non-matching search should show the no-results state")
        XCTAssertFalse(chase.exists)

        cancelSearch(in: app)
        XCTAssertTrue(chase.waitForExistence(timeout: 10),
                      "cancelling search should restore the full account list")
        XCTAssertTrue(searchControl(in: app).waitForExistence(timeout: 10),
                      "cancelling search should restore the toolbar search action")
        XCTAssertFalse(app.textFields["accounts.searchField"].exists,
                       "cancelling search must hide the fallback field")
        XCTAssertFalse(app.searchFields.firstMatch.exists,
                       "cancelling search must hide the native search field")

        tapSearch(in: app)
        let reopenedField = activeSearchField(in: app)
        XCTAssertTrue(reopenedField.waitForExistence(timeout: 10))
        typeSearchText("chase", in: reopenedField, app: app)
        XCTAssertTrue(chase.waitForExistence(timeout: 10),
                      "reopening search must focus the field again")
        cancelSearch(in: app)
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
    private func searchControl(in app: XCUIApplication) -> XCUIElement {
        let fallbackButton = app.buttons["accounts.search"]
        if fallbackButton.exists {
            return fallbackButton
        }
        return app.navigationBars.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Search"))
            .firstMatch
    }

    @MainActor
    private func tapSearch(in app: XCUIApplication) {
        let control = searchControl(in: app)
        XCTAssertTrue(control.waitForExistence(timeout: 10),
                      "the native or fallback search control should be visible")
        control.tap()
    }

    @MainActor
    private func activeSearchField(in app: XCUIApplication) -> XCUIElement {
        let fallbackField = app.textFields["accounts.searchField"]
        if fallbackField.exists {
            return fallbackField
        }
        return app.searchFields.firstMatch
    }

    @MainActor
    private func clearSearch(in app: XCUIApplication) {
        let fallbackClearButton = app.buttons["accounts.searchClear"]
        if fallbackClearButton.waitForExistence(timeout: 1) {
            fallbackClearButton.tap()
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
    private func cancelSearch(in app: XCUIApplication) {
        let nativeCancelButton = app.navigationBars.descendants(matching: .button)
            .matching(NSPredicate(format: "label CONTAINS[c] 'Cancel' OR label == 'Close'"))
            .firstMatch
        if nativeCancelButton.waitForExistence(timeout: 1) {
            nativeCancelButton.tap()
            return
        }

        let fallbackButton = app.buttons["accounts.search"]
        XCTAssertTrue(fallbackButton.waitForExistence(timeout: 10),
                      "the fallback cancel-search button should be visible")
        fallbackButton.tap()
    }
}
