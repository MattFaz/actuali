import XCTest

/// Repro for the inconsistent post-save behaviour report (issue #124).
///
/// The add-transaction form had two different endings: the tab-hosted flow
/// reset itself and switched to the Accounts overview, while the
/// sheet-presented flow (account detail "+") stayed open with a blank form.
/// Every entry point is a sheet now (the floating button on Budget, Accounts
/// and Reports, and the account detail's "+"), so all of them end the same
/// way: the form closes and the user lands back on the page it was opened from.
final class AddTransactionPostSaveUITests: XCTestCase {
    /// Types an amount on the keypad and taps the save button.
    @MainActor
    private func enterAmountAndSave(in app: XCUIApplication) {
        let amountField = app.textFields.matching(
            NSPredicate(format: "placeholderValue == '0.00'")
        ).firstMatch
        XCTAssertTrue(amountField.waitForExistence(timeout: 10), "amount field not found")
        amountField.tap()
        XCTAssertTrue(app.amountKeypad.waitForExistence(timeout: 5),
                      "keyboard did not appear")
        amountField.typeText("500")

        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "no Done key on the keypad")
        done.tap()
        XCTAssertTrue(app.amountKeypad.waitForNonExistence(timeout: 5),
                      "keyboard did not dismiss")

        // By identifier: the account detail's "+" toolbar button behind the
        // sheet carries the same "Add Transaction" label since #181.
        let save = app.buttons["addTransaction.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "save button not found")
        save.tap()
    }

    @MainActor
    func testSheetPresentedAddFlowDismissesToAccountListAfterSave() {
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

        // The sheet carries no title, so its close button marks it.
        let addSheet = app.buttons["addTransaction.close"]
        XCTAssertTrue(addSheet.waitForExistence(timeout: 5), "add sheet did not present")
        XCTAssertFalse(app.navigationBars["Add Transaction"].exists, "add sheet shows a title")

        enterAmountAndSave(in: app)

        // The sheet must close itself, landing back on the account's
        // transaction list — not stay open with a reset form.
        XCTAssertTrue(addSheet.waitForNonExistence(timeout: 10),
                      "add sheet stayed open after saving")
        XCTAssertTrue(app.navigationBars["Chase Checking"].waitForExistence(timeout: 5),
                      "did not land back on the account's transaction list")
    }

    @MainActor
    func testFloatingButtonAddFlowDismissesToBudgetAfterSave() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "1"]
        app.launch()

        // Demo data sets no default account, so the form falls back to the
        // first open account: Chase Checking.
        openAddTransactionSheet(in: app)
        enterAmountAndSave(in: app)

        // The sheet closes and the page it was opened from is still showing:
        // the save no longer routes to the account's transaction list.
        XCTAssertTrue(app.buttons["addTransaction.close"].waitForNonExistence(timeout: 10),
                      "add sheet stayed open after saving")
        expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: app.tabBars.buttons["Budget"])
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.navigationBars["Chase Checking"].exists,
                       "navigated to the account's list instead of staying on Budget")
    }

    @MainActor
    func testFloatingButtonAddFlowDismissesToAccountsAfterSave() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "0"]
        app.launch()

        let allAccountsRow = app.buttons.matching(identifier: "accounts.topBox").firstMatch
        XCTAssertTrue(allAccountsRow.waitForExistence(timeout: 10), "Accounts overview not found")

        openAddTransactionSheet(in: app)
        enterAmountAndSave(in: app)

        XCTAssertTrue(app.buttons["addTransaction.close"].waitForNonExistence(timeout: 10),
                      "add sheet stayed open after saving")
        XCTAssertTrue(allAccountsRow.waitForExistence(timeout: 10),
                      "did not return to the Accounts overview after saving")
        XCTAssertFalse(app.navigationBars["Chase Checking"].exists,
                       "navigated to the account's list instead of staying on the Accounts overview")
    }
}
