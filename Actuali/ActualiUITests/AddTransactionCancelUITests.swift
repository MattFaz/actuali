import XCTest

/// The tab-hosted add flow must offer a way out that discards everything
/// entered and returns to the user's Start Page (issue #281). Presented
/// flows (edit, account-detail "+") already had Cancel via dismiss; the tab
/// flow has nothing to dismiss to, so its Cancel resets the form and routes
/// to the Start Page tab instead.
final class AddTransactionCancelUITests: XCTestCase {
    /// Types an amount, then closes the form with the button beside the
    /// amount. The add flow has no Cancel row; the close button stays
    /// reachable with the keypad up, and discards without asking.
    @MainActor
    private func enterAmountAndCancel(in app: XCUIApplication) {
        let amountField = app.textFields.matching(
            NSPredicate(format: "placeholderValue == '0.00'")
        ).firstMatch
        XCTAssertTrue(amountField.waitForExistence(timeout: 10), "amount field not found")
        amountField.tap()
        XCTAssertTrue(app.amountKeypad.waitForExistence(timeout: 5),
                      "keyboard did not appear")
        amountField.typeText("500")
        XCTAssertFalse(app.buttons["Cancel"].exists, "add flow still shows a Cancel row")

        app.buttons["addTransaction.close"].tap()
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
        // Generous: the caller has just switched tabs, and rebuilding the form
        // takes well over 5s on a loaded CI runner (run 32860255135).
        waitForExpectations(timeout: 20)
    }

    @MainActor
    func testCancelReturnsToStartPageAndClearsTheForm() {
        let app = XCUIApplication()
        // -startTab feeds UserDefaults via the argument domain, the same key
        // the Settings Start Page picker persists.
        app.launchArguments = ["-loadDemoData", "-initialTab", "2", "-startTab", "budget"]
        app.launch()

        enterAmountAndCancel(in: app)

        // The Budget tab has no navigation header; verify the selected tab.
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: app.tabBars.buttons["Budget"])
        waitForExpectations(timeout: 5)

        // Back on the Add tab, the entered amount must be gone.
        app.tabBars.buttons["Add"].tap()
        assertAmountCleared(in: app)
    }

    @MainActor
    func testCancelStaysPutWhenStartPageIsAddTransaction() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2", "-startTab", "addTransaction"]
        app.launch()

        enterAmountAndCancel(in: app)

        // The Start Page is this tab: cancel stays put and discards the entry.
        assertAmountCleared(in: app)
        XCTAssertTrue(app.tabBars.buttons["Accounts"].isHittable,
                      "tab bar not reachable after cancelling in place")
    }
}
