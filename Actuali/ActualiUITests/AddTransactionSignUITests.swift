import XCTest

/// The amount's sign is the transaction's direction, as in Actual: the sign
/// beside the amount flips it, and so does the keypad's ±, which stays under
/// the thumb.
final class AddTransactionSignUITests: XCTestCase {
    @MainActor
    func testSignButtonSwitchesBetweenExpenseAndIncome() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2"]
        app.launch()

        let sign = app.buttons["addTransaction.sign"]
        XCTAssertTrue(sign.waitForExistence(timeout: 10))
        XCTAssertEqual(sign.value as? String, "Outflow", "a new transaction starts as an expense")

        XCTAssertTrue(app.amountKeypad.waitForExistence(timeout: 10), "keyboard did not appear")

        sign.tap()
        XCTAssertEqual(sign.value as? String, "Inflow")
        sign.tap()
        XCTAssertEqual(sign.value as? String, "Outflow")

        let flip = app.amountKeypad.buttons["Flip sign"]
        XCTAssertTrue(flip.exists, "no ± on the keypad")
        flip.tap()
        XCTAssertEqual(sign.value as? String, "Inflow")
        flip.tap()
        XCTAssertEqual(sign.value as? String, "Outflow")
    }

    @MainActor
    func testChoosingATransferKeepsTheSignEnabled() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2"]
        app.launch()

        let sign = app.buttons["addTransaction.sign"]
        XCTAssertTrue(sign.waitForExistence(timeout: 10))
        app.buttons["addTransaction.payee"].tap()
        let account = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'payeePicker.transfer.' AND label CONTAINS 'Ally Savings'"
        )).firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.tap()
        XCTAssertTrue(sign.waitForExistence(timeout: 5))
        XCTAssertTrue(sign.isEnabled)
    }

    @MainActor
    func testConvertingAnExistingExpenseDisablesTheSign() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "0", "-transactionDisplayMode", "flat"]
        app.launch()

        let allAccounts = app.staticTexts["All Accounts"].firstMatch
        XCTAssertTrue(allAccounts.waitForExistence(timeout: 10))
        allAccounts.tap()
        let transaction = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'transactionRow.' AND label CONTAINS 'Chipotle'"
        )).firstMatch
        XCTAssertTrue(transaction.waitForExistence(timeout: 10))
        transaction.tap()
        XCTAssertTrue(app.navigationBars["Edit Transaction"].waitForExistence(timeout: 5))

        let sign = app.buttons["addTransaction.sign"]
        XCTAssertTrue(sign.waitForExistence(timeout: 5))
        XCTAssertTrue(sign.isEnabled)

        app.buttons["addTransaction.payee"].tap()
        let transferSearch = app.textFields["Search payees"]
        XCTAssertTrue(transferSearch.waitForExistence(timeout: 5))
        transferSearch.typeText("Ally Savings")
        let account = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'payeePicker.transfer.' AND label CONTAINS 'Ally Savings'"
        )).firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.tap()
        XCTAssertTrue(sign.waitForExistence(timeout: 5))
        XCTAssertFalse(sign.isEnabled)

        app.buttons["addTransaction.payee"].tap()
        let search = app.textFields["Search payees"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("Chipotle")
        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(sign.waitForExistence(timeout: 5))
        XCTAssertTrue(sign.isEnabled)
        sign.tap()
        XCTAssertEqual(sign.value as? String, "Inflow")
    }

    @MainActor
    func testSignButtonReversesATransferWithoutChangingItsAmount() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2"]
        app.launch()

        let amount = app.textFields.matching(NSPredicate(format: "placeholderValue == '0.00'")).firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 10))
        app.keys["5"].tap()
        app.buttons["addTransaction.payee"].tap()
        let savings = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'payeePicker.transfer.' AND label CONTAINS 'Ally Savings'"
        )).firstMatch
        XCTAssertTrue(savings.waitForExistence(timeout: 5))
        savings.tap()

        let sign = app.buttons["addTransaction.sign"]
        XCTAssertEqual(sign.value as? String, "Transfer from Chase Checking to Ally Savings")
        sign.tap()
        XCTAssertEqual(sign.value as? String, "Transfer from Ally Savings to Chase Checking")
        XCTAssertEqual(amount.value as? String, "0.05")

        sign.tap()
        XCTAssertEqual(sign.value as? String, "Transfer from Chase Checking to Ally Savings")
        XCTAssertEqual(amount.value as? String, "0.05")
    }
}
