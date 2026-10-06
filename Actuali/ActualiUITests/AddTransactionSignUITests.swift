import XCTest

/// The amount's sign is the transaction's direction, as in Actual: the
/// keyboard's ± key and the sign beside the amount both flip it.
final class AddTransactionSignUITests: XCTestCase {
    @MainActor
    func testFlipSignKeyAndSignButtonSwitchBetweenExpenseAndIncome() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2"]
        app.launch()

        let sign = app.buttons["addTransaction.sign"]
        XCTAssertTrue(sign.waitForExistence(timeout: 10))
        XCTAssertEqual(sign.value as? String, "Outflow", "a new transaction starts as an expense")

        // The decimal pad has no minus key; the keyboard bar's ± is the way.
        let flip = app.buttons["Flip sign"]
        XCTAssertTrue(flip.waitForExistence(timeout: 10), "no ± key above the amount keyboard")
        flip.tap()
        XCTAssertEqual(sign.value as? String, "Inflow")

        flip.tap()
        XCTAssertEqual(sign.value as? String, "Outflow")

        // Tapping the sign itself does the same.
        sign.tap()
        XCTAssertEqual(sign.value as? String, "Inflow")
    }

    @MainActor
    func testChoosingATransferKeepsBothSignControlsEnabled() {
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
        XCTAssertTrue(sign.isEnabled)
        let amount = app.textFields.matching(NSPredicate(format: "placeholderValue == '0.00'")).firstMatch
        amount.tap()
        let flip = app.buttons["Flip sign"]
        XCTAssertTrue(flip.waitForExistence(timeout: 5))
        XCTAssertTrue(flip.isEnabled)
    }

    @MainActor
    func testConvertingAnExistingExpenseDisablesTheKeyboardSignKey() {
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

        let amount = app.textFields.matching(NSPredicate(format: "placeholderValue == '0.00'")).firstMatch
        amount.tap()
        let flip = app.buttons["Flip sign"]
        XCTAssertTrue(flip.waitForExistence(timeout: 5))
        XCTAssertTrue(flip.isEnabled)

        app.buttons["addTransaction.payee"].tap()
        let transferSearch = app.textFields["Search payees"]
        XCTAssertTrue(transferSearch.waitForExistence(timeout: 5))
        transferSearch.typeText("Ally Savings")
        let account = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'payeePicker.transfer.' AND label CONTAINS 'Ally Savings'"
        )).firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.tap()
        amount.tap()
        XCTAssertTrue(flip.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["addTransaction.sign"].isEnabled)
        XCTAssertFalse(flip.isEnabled)

        app.buttons["addTransaction.payee"].tap()
        let search = app.textFields["Search payees"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("Chipotle")
        app.navigationBars.buttons["Done"].tap()
        amount.tap()
        XCTAssertTrue(flip.waitForExistence(timeout: 5))
        XCTAssertTrue(flip.isEnabled)
        flip.tap()
        XCTAssertEqual(app.buttons["addTransaction.sign"].value as? String, "Inflow")
    }

    @MainActor
    func testKeyboardAndSignButtonReverseATransferWithoutChangingItsAmount() {
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
        amount.tap()
        let flip = app.buttons["Flip sign"]
        XCTAssertTrue(flip.waitForExistence(timeout: 5))
        XCTAssertTrue(flip.isEnabled)
        flip.tap()
        XCTAssertEqual(sign.value as? String, "Transfer from Ally Savings to Chase Checking")
        XCTAssertEqual(amount.value as? String, "0.05")

        sign.tap()
        XCTAssertEqual(sign.value as? String, "Transfer from Chase Checking to Ally Savings")
        XCTAssertEqual(amount.value as? String, "0.05")
    }
}
