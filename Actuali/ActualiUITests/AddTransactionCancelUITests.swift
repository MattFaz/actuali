import XCTest

/// The tab-hosted add flow must offer a Cancel that discards everything
/// entered (issue #281). Presented flows (edit, account-detail "+") already
/// had Cancel via dismiss; the tab flow has nothing to dismiss to, so its
/// Cancel resets the form in place.
final class AddTransactionCancelUITests: XCTestCase {

    @MainActor
    func testTabHostedAddFlowCancelClearsTheForm() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2"]
        app.launch()

        let amountField = app.textFields.matching(
            NSPredicate(format: "placeholderValue == '0.00'")
        ).firstMatch
        XCTAssertTrue(amountField.waitForExistence(timeout: 10), "amount field not found")
        amountField.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "keyboard did not appear")
        amountField.typeText("500")

        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "no Done bar above the decimal pad")
        done.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5),
                      "keyboard did not dismiss")

        let cancel = app.navigationBars.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5),
                      "tab-hosted add flow has no Cancel button")
        cancel.tap()

        // The entered amount must be gone: the field shows its placeholder
        // again, and the form stays put (still the Add Transaction tab).
        XCTAssertTrue(app.navigationBars["Add Transaction"].waitForExistence(timeout: 5),
                      "cancel navigated away from the add tab")
        let cleared = NSPredicate(format: "value == '0.00' OR value == ''")
        expectation(for: cleared, evaluatedWith: amountField)
        waitForExpectations(timeout: 5)
    }
}
