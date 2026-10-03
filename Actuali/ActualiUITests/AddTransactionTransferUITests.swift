import XCTest

/// Add Transaction is one page, as in Actual: there is no Expense / Income /
/// Transfer control, and a transfer is made by choosing an account as the
/// payee. The sign then says which way the money goes.
final class AddTransactionTransferUITests: XCTestCase {
    @MainActor private func launchAddTab() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2"]
        app.launch()
        XCTAssertTrue(app.buttons["addTransaction.payee"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func testThereIsNoTypeControl() {
        let app = launchAddTab()
        XCTAssertEqual(app.segmentedControls.count, 0, "the type control is gone")
        for name in ["Expense", "Income", "Transfer"] {
            XCTAssertFalse(app.buttons[name].exists, "no \(name) button on the form")
        }
    }

    @MainActor
    func testChoosingAnAccountAsThePayeeMakesATransfer() {
        let app = launchAddTab()
        XCTAssertTrue(app.buttons["addTransaction.category"].exists, "a regular transaction has a category")

        app.buttons["addTransaction.payee"].tap()
        XCTAssertTrue(app.staticTexts["Transfer to / from"].waitForExistence(timeout: 5),
                      "the payee list offers accounts as transfers")
        let savings = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'payeePicker.transfer.'"))
            .element(boundBy: 0)
        XCTAssertTrue(savings.waitForExistence(timeout: 5))
        savings.tap()

        // The payee row now names the other account, the money goes out of
        // this one, and a transfer between on-budget accounts takes no category.
        let payee = app.buttons["addTransaction.payee"]
        XCTAssertTrue(payee.waitForExistence(timeout: 5))
        XCTAssertTrue(payee.label.contains("Transfer to"), "payee row reads as a transfer, got: \(payee.label)")
        XCTAssertEqual(app.buttons["addTransaction.sign"].value as? String, "Transfer to")
        XCTAssertFalse(app.buttons["addTransaction.category"].exists, "an on-budget transfer has no category")

        // The ± key reverses the transfer.
        app.buttons["addTransaction.sign"].tap()
        XCTAssertEqual(app.buttons["addTransaction.sign"].value as? String, "Transfer from")
        XCTAssertTrue(payee.label.contains("Transfer from"), "payee row follows the sign, got: \(payee.label)")
    }

    @MainActor
    func testPickingARegularPayeeAfterATransferBringsTheCategoryBack() {
        let app = launchAddTab()
        app.buttons["addTransaction.payee"].tap()
        let account = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'payeePicker.transfer.'"))
            .element(boundBy: 0)
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.tap()
        XCTAssertFalse(app.buttons["addTransaction.category"].exists)

        app.buttons["addTransaction.payee"].tap()
        let search = app.textFields["Search payees"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("Coffee Shop")
        app.navigationBars.buttons["Done"].tap()

        XCTAssertTrue(app.buttons["addTransaction.category"].waitForExistence(timeout: 5),
                      "a regular payee is an ordinary transaction again")
        XCTAssertEqual(app.buttons["addTransaction.sign"].value as? String, "Outflow")
    }

    @MainActor
    func testSavingATransferWritesItAndLandsOnTheAccount() {
        let app = launchAddTab()
        let amountField = app.textFields.matching(NSPredicate(format: "placeholderValue == '0.00'")).firstMatch
        XCTAssertTrue(amountField.waitForExistence(timeout: 10))
        amountField.typeText("1234")

        app.buttons["addTransaction.payee"].tap()
        let account = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'payeePicker.transfer.'"))
            .element(boundBy: 0)
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.tap()
        XCTAssertTrue(app.buttons["addTransaction.payee"].waitForExistence(timeout: 5))

        let save = app.buttons["Add Transfer"]
        for _ in 0..<4 where !save.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(save.isHittable, "the form saves as a transfer")
        save.tap()

        // Saved: the form resets and the account's list shows the new row.
        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '12.34'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the transfer shows in the account's list")
    }

    @MainActor
    func testAnExistingTransferOpensAsATransferWithItsSignLocked() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-resetStatusFilterState"]
        app.launch()
        app.tabBars.buttons["Accounts"].tap()
        let allAccounts = app.staticTexts["All Accounts"].firstMatch
        XCTAssertTrue(allAccounts.waitForExistence(timeout: 10))
        allAccounts.tap()
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10))
        searchField.tap()
        searchField.typeText("Toyota")

        let transferRow = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Toyota'")).firstMatch
        XCTAssertTrue(transferRow.waitForExistence(timeout: 10), "the demo's loan payment transfer")
        transferRow.tap()

        let payee = app.buttons["addTransaction.payee"]
        XCTAssertTrue(payee.waitForExistence(timeout: 10))
        XCTAssertTrue(payee.label.contains("Transfer"), "opens as a transfer, got: \(payee.label)")
        XCTAssertFalse(app.buttons["addTransaction.sign"].isEnabled,
                       "an existing transfer's direction is fixed by its two legs")
    }
}
