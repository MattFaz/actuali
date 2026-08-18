import XCTest

/// The tab-hosted add flow must offer a Cancel that discards everything
/// entered and returns to the user's Start Page (issue #281). Presented
/// flows (edit, account-detail "+") already had Cancel via dismiss; the tab
/// flow has nothing to dismiss to, so its Cancel resets the form and routes
/// to the Start Page tab instead.
final class AddTransactionCancelUITests: XCTestCase {

    /// Types an amount and taps Cancel with the keyboard still up — the
    /// normal mid-entry state a cancel arrives from.
    @MainActor
    private func enterAmountAndCancel(in app: XCUIApplication) {
        let amountField = app.textFields.matching(
            NSPredicate(format: "placeholderValue == '0.00'")
        ).firstMatch
        XCTAssertTrue(amountField.waitForExistence(timeout: 10), "amount field not found")
        amountField.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "keyboard did not appear")
        amountField.typeText("500")

        let cancel = app.navigationBars.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5),
                      "tab-hosted add flow has no Cancel button")
        cancel.tap()
    }

    /// Asserts the amount field shows its placeholder again — the entered
    /// amount was discarded.
    @MainActor
    private func assertAmountCleared(in app: XCUIApplication) {
        let amountField = app.textFields.matching(
            NSPredicate(format: "placeholderValue == '0.00'")
        ).firstMatch
        XCTAssertTrue(amountField.waitForExistence(timeout: 5), "amount field not found")
        let cleared = NSPredicate(format: "value == '0.00' OR value == ''")
        expectation(for: cleared, evaluatedWith: amountField)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testCancelReturnsToStartPageAndClearsTheForm() throws {
        let app = XCUIApplication()
        // -startTab feeds UserDefaults via the argument domain, the same key
        // the Settings Start Page picker persists.
        app.launchArguments = ["-loadDemoData", "-initialTab", "2", "-startTab", "budget"]
        app.launch()

        enterAmountAndCancel(in: app)

        XCTAssertTrue(app.navigationBars["Budget"].waitForExistence(timeout: 5),
                      "cancel did not land on the configured Start Page")

        // Back on the Add tab, the entered amount must be gone.
        app.tabBars.buttons["Add"].tap()
        assertAmountCleared(in: app)
    }

    @MainActor
    func testCancelStaysPutWhenStartPageIsAddTransaction() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2", "-startTab", "addTransaction"]
        app.launch()

        enterAmountAndCancel(in: app)

        // The Start Page is this tab: cancel stays put, discards the entry,
        // and dismisses the mid-entry keyboard (which covers the tab bar).
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5),
                      "keyboard stayed up after cancelling in place")
        assertAmountCleared(in: app)
        XCTAssertTrue(app.tabBars.buttons["Accounts"].isHittable,
                      "tab bar not reachable after cancelling in place")
    }
}
