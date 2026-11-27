import XCTest

/// The add flow must offer a way out that discards everything entered
/// (issue #281). The form is a sheet over the page the Quick Add button was
/// tapped on, so closing it dismisses back to that page rather than jumping to
/// the Start Page.
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
        // Generous: the caller has just reopened the sheet, and rebuilding the
        // form takes well over 5s on a loaded CI runner (run 32860255135).
        waitForExpectations(timeout: 20)
    }

    @MainActor
    func testCloseStaysOnTheOpeningPageAndClearsTheForm() {
        let app = XCUIApplication()
        // -startTab feeds UserDefaults via the argument domain, the same key
        // the Settings Start Page picker persists. It differs from the page
        // the sheet opens from, so a jump to the Start Page would show.
        app.launchArguments = ["-loadDemoData", "-initialTab", "1", "-startTab", "accounts"]
        app.launch()

        openAddTransactionSheet(in: app)
        enterAmountAndCancel(in: app)

        XCTAssertTrue(app.buttons["addTransaction.close"].waitForNonExistence(timeout: 10),
                      "add sheet stayed open after closing")
        // The Budget tab has no navigation header; verify the selected tab.
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: app.tabBars.buttons["Budget"])
        waitForExpectations(timeout: 5)

        // Reopened, the form starts blank: the entered amount must be gone.
        openAddTransactionSheet(in: app)
        assertAmountCleared(in: app)
    }

    /// Add used to be a tab, so a Start Page of "addTransaction" may still be
    /// stored from then.
    @MainActor
    func testStoredAddTransactionStartPageOpensAccounts() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-startTab", "addTransaction"]
        app.launch()

        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: app.tabBars.buttons["Accounts"])
        waitForExpectations(timeout: 15)
        XCTAssertFalse(app.buttons["addTransaction.close"].exists,
                       "the app opened on the add form instead of the page underneath")
    }
}
