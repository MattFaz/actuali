import XCTest

/// Add Transaction is one page, as in Actual: there is no Expense / Income /
/// Transfer control, and a transfer is made by choosing an account as the
/// payee. The sign then says which way the money goes.
final class AddTransactionTransferUITests: XCTestCase {
    @MainActor private func launchAddSheet() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-presentAddTransaction"]
        app.launch()
        XCTAssertTrue(app.buttons["addTransaction.payee"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    func testThereIsNoTypeControl() {
        let app = launchAddSheet()
        XCTAssertEqual(app.segmentedControls.count, 0, "the type control is gone")
        for name in ["Expense", "Income", "Transfer"] {
            XCTAssertFalse(app.buttons[name].exists, "no \(name) button on the form")
        }
    }

    @MainActor
    func testChoosingAnAccountAsThePayeeMakesATransfer() {
        let app = launchAddSheet()
        XCTAssertTrue(app.buttons["addTransaction.category"].exists, "a regular transaction has a category")

        app.buttons["addTransaction.payee"].tap()
        let transferSection = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Transfer to / from")).firstMatch
        XCTAssertTrue(transferSection.waitForExistence(timeout: 5),
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
        XCTAssertEqual(app.buttons["addTransaction.sign"].value as? String, "Transfer from Chase Checking to Ally Savings")
        XCTAssertFalse(app.buttons["addTransaction.category"].exists, "an on-budget transfer has no category")

        // The ± key reverses the transfer.
        app.buttons["addTransaction.sign"].tap()
        XCTAssertEqual(app.buttons["addTransaction.sign"].value as? String, "Transfer from Ally Savings to Chase Checking")
        XCTAssertTrue(payee.label.contains("Transfer from"), "payee row follows the sign, got: \(payee.label)")
    }

    @MainActor
    func testPickingARegularPayeeAfterATransferBringsTheCategoryBack() {
        let app = launchAddSheet()
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
    func testSavingATransferWritesItAndClosesTheForm() {
        saveTransfer(isInflow: false)
    }

    @MainActor
    func testSavingAnIncomingTransferWritesItToTheFormsAccount() {
        saveTransfer(isInflow: true)
    }

    @MainActor
    private func saveTransfer(isInflow: Bool) {
        let app = launchAddSheet()
        let amountField = app.textFields.matching(NSPredicate(format: "placeholderValue == '0.00'")).firstMatch
        XCTAssertTrue(amountField.waitForExistence(timeout: 10))
        amountField.typeText("1234")

        app.buttons["addTransaction.payee"].tap()
        let account = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'payeePicker.transfer.'"))
            .element(boundBy: 0)
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.tap()
        XCTAssertTrue(app.buttons["addTransaction.payee"].waitForExistence(timeout: 5))

        if isInflow {
            app.buttons["addTransaction.sign"].tap()
        }
        let save = app.buttons["Add Transfer"]
        for _ in 0..<4 where !save.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(save.isHittable, "the form saves as a transfer")
        save.tap()

        // Saved: the sheet closes, and the form's account lists the new row.
        XCTAssertTrue(app.buttons["addTransaction.payee"].waitForNonExistence(timeout: 10),
                      "the form should close after saving a transfer")
        app.tabBars.buttons["Accounts"].tap()
        let accountRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Chase Checking'")
        ).firstMatch
        XCTAssertTrue(accountRow.waitForExistence(timeout: 10), "Chase Checking row not found")
        accountRow.tap()
        XCTAssertTrue(app.navigationBars["Chase Checking"].waitForExistence(timeout: 10),
                      "the form's account should open")
        let row = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '12.34'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the transfer shows in the account's list")
    }

    @MainActor
    func testAnExistingTransferOpensAsATransferAndItsSignReversesIt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-resetStatusFilterState", "-transactionDisplayMode", "flat"]
        app.launch()
        app.tabBars.buttons["Accounts"].tap()
        let allAccounts = app.staticTexts["All Accounts"].firstMatch
        XCTAssertTrue(allAccounts.waitForExistence(timeout: 10))
        allAccounts.tap()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10))
        tapSearch(in: app, customButtonIdentifier: "transactions.search")
        let searchField = activeSearchField(in: app, customFieldIdentifier: "transactions.searchField")
        typeSearchText("Toyota", in: searchField)

        let transferRow = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'transactionRow.' AND label CONTAINS 'Toyota'"
        )).firstMatch
        XCTAssertTrue(transferRow.waitForExistence(timeout: 10), "the demo's loan payment transfer")
        transferRow.tap()

        let payee = app.buttons["addTransaction.payee"]
        XCTAssertTrue(payee.waitForExistence(timeout: 10))
        XCTAssertTrue(payee.label.contains("Transfer"), "opens as a transfer, got: \(payee.label)")
        // The sign reverses an existing transfer, as in Actual (GH #844).
        let sign = app.buttons["addTransaction.sign"]
        XCTAssertTrue(sign.isEnabled, "an existing transfer's sign reverses it")
        let direction = try XCTUnwrap(sign.value as? String)
        sign.tap()
        let reversed = try XCTUnwrap(sign.value as? String)
        XCTAssertNotEqual(reversed, direction)
        XCTAssertTrue(reversed.hasPrefix("Transfer from "), "still a transfer, got: \(reversed)")
        let accounts = { (value: String) in value.dropFirst("Transfer from ".count).components(separatedBy: " to ") }
        XCTAssertEqual(accounts(reversed), accounts(direction).reversed(), "the two accounts swap")
        let originalPayee = payee.label
        payee.tap()
        let account = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'payeePicker.transfer.'")).firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 5), "existing transfers must offer replacement accounts")
        let search = app.textFields["Search payees"]
        search.typeText("Coffee Shop")
        XCTAssertFalse(app.buttons["Use \"Coffee Shop\""].exists, "existing transfers cannot select a custom payee")
        app.navigationBars.buttons["Done"].tap()
        XCTAssertEqual(payee.label, originalPayee, "Done must preserve the existing transfer's partner")
        payee.tap()
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.tap()
        XCTAssertTrue(payee.waitForExistence(timeout: 5))
        XCTAssertTrue(payee.label.contains("Transfer"), "retargeting must keep the transaction a transfer")
    }

    @MainActor
    func testDoneWithoutAPayeePreservesANewTransfer() {
        let app = launchAddSheet()
        app.buttons["addTransaction.payee"].tap()
        let account = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'payeePicker.transfer.'")).firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.tap()
        let payee = app.buttons["addTransaction.payee"]
        let originalPayee = payee.label
        payee.tap()
        app.navigationBars.buttons["Done"].tap()
        XCTAssertEqual(payee.label, originalPayee, "Done must not silently turn a transfer into an expense")
        XCTAssertFalse(app.buttons["addTransaction.category"].exists)
    }

    @MainActor
    func testReopeningATransferDoesNotSearchForThePreviousRegularPayee() {
        let app = launchAddSheet()
        app.buttons["addTransaction.payee"].tap()
        let search = app.textFields["Search payees"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("Coffee Shop")
        app.navigationBars.buttons["Done"].tap()
        app.buttons["addTransaction.payee"].tap()
        search.typeText("Ally Savings")
        let account = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'payeePicker.transfer.'")).firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.tap()
        app.buttons["addTransaction.payee"].tap()
        XCTAssertEqual(search.value as? String, "Search payees", "a transfer opens with an empty account search")
        XCTAssertTrue(account.waitForExistence(timeout: 5))
    }

    @MainActor
    func testSelectingTheTransferPartnerAsTheAccountKeepsATransfer() {
        let app = launchAddSheet()
        app.buttons["addTransaction.payee"].tap()
        let partner = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'payeePicker.transfer.' AND label CONTAINS 'Ally Savings'"
        )).firstMatch
        XCTAssertTrue(partner.waitForExistence(timeout: 5))
        partner.tap()
        app.buttons["addTransaction.account"].tap()
        // The Accounts page stays in the hierarchy behind the sheet and names
        // Ally Savings too; only the picker's row is hittable.
        let rows = app.buttons["Ally Savings"].exists
            ? app.buttons.matching(identifier: "Ally Savings")
            : app.staticTexts.matching(identifier: "Ally Savings")
        var savings: XCUIElement?
        for _ in 0..<10 where savings == nil {
            savings = rows.allElementsBoundByIndex.first { $0.isHittable }
            if savings == nil {
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        XCTAssertNotNil(savings, "Ally Savings row not found in the account picker")
        savings?.tap()

        let payee = app.buttons["addTransaction.payee"]
        XCTAssertTrue(payee.waitForExistence(timeout: 5))
        XCTAssertTrue(payee.label.contains("Transfer to: Chase Checking"),
                      "selecting the partner should swap the accounts and keep the transfer")
        XCTAssertEqual(app.buttons["addTransaction.sign"].value as? String, "Transfer from Ally Savings to Chase Checking")
        XCTAssertFalse(app.buttons["addTransaction.category"].exists)
    }
}
