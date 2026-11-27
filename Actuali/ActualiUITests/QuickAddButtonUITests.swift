import XCTest

/// The round + that replaced the Add tab (#350): it floats over Budget,
/// Accounts, Reports and the transaction screens, opens the entry form as a
/// sheet (on an account's own screen, for that account), and More → Display
/// can hide it.
final class QuickAddButtonUITests: XCTestCase {
    /// `-showsQuickAddButton YES` forces the setting on through the arguments
    /// domain, so a value left behind by an earlier run stays out of the test.
    @MainActor
    private func launch(initialTab: Int) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", String(initialTab), "-showsQuickAddButton", "YES"]
        app.launch()
        return app
    }

    @MainActor
    func testButtonShowsOnBudgetAccountsAndReportsButNotMore() {
        let app = launch(initialTab: 0)
        let addButton = app.buttons["quickAdd.button"]

        for tab in ["Accounts", "Budget", "Reports"] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(addButton.waitForExistence(timeout: 10), "no Quick Add button on \(tab)")
        }

        app.tabBars.buttons["More"].tap()
        XCTAssertTrue(addButton.waitForNonExistence(timeout: 10), "Quick Add button showing on More")
    }

    @MainActor
    func testTappingTheButtonOpensTheFormWithTheAmountFocused() {
        let app = launch(initialTab: 0)

        openAddTransactionSheet(in: app)
        XCTAssertTrue(app.buttons["addTransaction.payee"].waitForExistence(timeout: 10),
                      "the sheet should show the transaction form")
        XCTAssertTrue(app.amountKeypad.waitForExistence(timeout: 10),
                      "the amount should be focused, with the keypad up")

        let amountField = app.textFields.matching(
            NSPredicate(format: "placeholderValue == '0.00'")
        ).firstMatch
        app.keys["5"].tap()
        XCTAssertEqual(amountField.value as? String, "0.05",
                       "keypad input did not land in the amount field")
    }

    @MainActor
    func testOnAnAccountTheButtonOpensTheFormForThatAccount() {
        let app = launch(initialTab: 0)

        // Demo data sets no default account, so a form that ignored the screen
        // would open on the first open account, Chase Checking.
        let accountRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Ally Savings'")
        ).firstMatch
        XCTAssertTrue(accountRow.waitForExistence(timeout: 10), "Ally Savings row not found")
        accountRow.tap()

        openAddTransactionSheet(in: app)
        let account = app.buttons["addTransaction.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 10), "the form has no account row")
        XCTAssertTrue(account.label.contains("Ally Savings"),
                      "the form should open on the account Quick Add was tapped in, not \(account.label)")
    }

    @MainActor
    func testButtonShowsOnAllAccountsUntilTransactionsAreBeingSelected() {
        let app = launch(initialTab: 0)

        let allAccounts = app.buttons["accounts.topBox"]
        XCTAssertTrue(allAccounts.waitForExistence(timeout: 20), "Accounts did not open")
        allAccounts.tap()
        XCTAssertTrue(app.navigationBars["All Accounts"].waitForExistence(timeout: 10), "All Accounts did not open")
        XCTAssertTrue(app.buttons["quickAdd.button"].waitForExistence(timeout: 10),
                      "no Quick Add button on All Accounts")

        app.buttons["transactions.selectionMode"].tap()
        XCTAssertTrue(app.buttons["quickAdd.button"].waitForNonExistence(timeout: 10),
                      "the button stays up while transactions are being selected")
    }

    /// Starts switched off through the arguments domain, which is never
    /// written back, and only ever switches the setting on: a failure midway
    /// can't leave the button hidden for the tests that run after this one.
    @MainActor
    func testSwitchedOffTheButtonIsHiddenUntilSwitchedBackOn() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "0", "-showsQuickAddButton", "NO"]
        app.launch()

        XCTAssertTrue(app.buttons["accounts.topBox"].waitForExistence(timeout: 20), "Accounts did not open")
        XCTAssertFalse(app.buttons["quickAdd.button"].exists, "the button shows on Accounts while switched off")

        app.tabBars.buttons["More"].tap()
        app.buttons["Display"].tap()
        let toggle = app.switches["displaySettings.quickAddButton"]
        for _ in 0..<8 where !toggle.exists {
            app.swipeUp()
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Show Quick Add Button switch not found in Display")
        XCTAssertEqual(toggle.value as? String, "0", "the switch should reflect the stored setting")

        tapControl(toggle) { toggle.value as? String == "1" }
        app.tabBars.buttons["Accounts"].tap()
        XCTAssertTrue(app.buttons["quickAdd.button"].waitForExistence(timeout: 10),
                      "the button did not appear on Accounts after switching it on")
    }
}
