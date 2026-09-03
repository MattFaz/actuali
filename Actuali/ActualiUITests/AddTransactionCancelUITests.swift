import XCTest

/// The tab-hosted add flow must offer a Cancel that discards everything
/// entered and returns to the user's Start Page (issue #281). Presented
/// flows (edit, account-detail "+") already had Cancel via dismiss; the tab
/// flow has nothing to dismiss to, so its Cancel resets the form and routes
/// to the Start Page tab instead.
final class AddTransactionCancelUITests: XCTestCase {

    /// Types an amount, drops the keyboard the way the form offers (the Done
    /// bar above the decimal pad), then taps the Cancel row at the foot of the
    /// form — Cancel lives below the save button now, not in the navigation
    /// bar, so it sits behind the keyboard mid-entry.
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

        app.buttons["Done"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5),
                      "keyboard did not dismiss after tapping Done")

        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5),
                      "tab-hosted add flow has no Cancel button")
        var scrollsLeft = 5
        while !cancel.isHittable && scrollsLeft > 0 {
            app.swipeUp()
            scrollsLeft -= 1
        }
        XCTAssertTrue(cancel.isHittable, "Cancel row not reachable at the foot of the form")
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

        // The Start Page is this tab: cancel stays put and discards the entry.
        assertAmountCleared(in: app)
        XCTAssertTrue(app.tabBars.buttons["Accounts"].isHittable,
                      "tab bar not reachable after cancelling in place")
    }
}
