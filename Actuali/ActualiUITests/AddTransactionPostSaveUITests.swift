import XCTest

/// Repro for the inconsistent post-save behaviour report (issue #124).
///
/// The add-transaction form had two different endings: the tab-hosted flow
/// reset itself and switched to the Accounts overview, while the
/// sheet-presented flow (account detail "+") stayed open with a blank form.
/// Both must now end the same way: the form closes and the user lands on the
/// saved transaction's account list.
final class AddTransactionPostSaveUITests: XCTestCase {

    /// Types an amount on the decimal pad and taps the save button.
    @MainActor
    private func enterAmountAndSave(in app: XCUIApplication) {
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

        // Scoped to the form: the account detail's "+" toolbar button behind
        // the sheet carries the same "Add Transaction" label since #181.
        let save = app.collectionViews.buttons["Add Transaction"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "save button not found")
        save.tap()
    }

    @MainActor
    func testSheetPresentedAddFlowDismissesToAccountListAfterSave() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "0"]
        app.launch()

        let accountRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Chase Checking'")
        ).firstMatch
        XCTAssertTrue(accountRow.waitForExistence(timeout: 10), "Chase Checking row not found")
        accountRow.tap()

        let addButton = app.navigationBars.buttons["Add Transaction"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5), "'+' toolbar button not found")
        addButton.tap()

        let addTitle = app.navigationBars["Add Transaction"]
        XCTAssertTrue(addTitle.waitForExistence(timeout: 5), "add sheet did not present")

        enterAmountAndSave(in: app)

        // The sheet must close itself, landing back on the account's
        // transaction list — not stay open with a reset form.
        XCTAssertTrue(addTitle.waitForNonExistence(timeout: 10),
                      "add sheet stayed open after saving")
        XCTAssertTrue(app.navigationBars["Chase Checking"].waitForExistence(timeout: 5),
                      "did not land back on the account's transaction list")
    }

    @MainActor
    func testTabHostedAddFlowNavigatesToAccountListAfterSave() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2"]
        app.launch()

        // Demo data sets no default account, so the tab-hosted form falls
        // back to the first open account: Chase Checking.
        enterAmountAndSave(in: app)

        // The form must end on the saved transaction's account list, not the
        // Accounts overview.
        XCTAssertTrue(app.navigationBars["Chase Checking"].waitForExistence(timeout: 10),
                      "did not land on the account's transaction list after saving")
    }
}
