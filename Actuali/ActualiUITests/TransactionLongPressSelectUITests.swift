import XCTest

final class TransactionLongPressSelectUITests: XCTestCase {
    @MainActor
    func testLongPressOpensSelectionModeAndSelectsTheRow() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-transactionDisplayMode", "flat",
        ]
        app.launch()

        app.tabBars.buttons["Accounts"].tap()
        let allAccounts = app.staticTexts["All Accounts"].firstMatch
        XCTAssertTrue(allAccounts.waitForExistence(timeout: 10))
        allAccounts.tap()

        let selectionModeButton = app.buttons["transactions.selectionMode"]
        XCTAssertTrue(selectionModeButton.waitForExistence(timeout: 10))
        XCTAssertEqual(selectionModeButton.label, "Select")

        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'transactionRow.'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 0.9)

        XCTAssertTrue(selectionModeButton.waitForExistence(timeout: 2))
        XCTAssertEqual(selectionModeButton.label, "Done")
        let deleteButton = app.buttons["Delete 1 selected transaction"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 2))
        XCTAssertTrue(deleteButton.isEnabled)
    }

    @MainActor
    private func openAllAccountsSelecting(_ app: XCUIApplication) -> [XCUIElement] {
        app.launchArguments = [
            "-loadDemoData",
            "-transactionDisplayMode", "flat",
        ]
        app.launch()
        app.tabBars.buttons["Accounts"].tap()
        let allAccounts = app.staticTexts["All Accounts"].firstMatch
        XCTAssertTrue(allAccounts.waitForExistence(timeout: 10))
        allAccounts.tap()

        let selectionModeButton = app.buttons["transactions.selectionMode"]
        XCTAssertTrue(selectionModeButton.waitForExistence(timeout: 10))
        selectionModeButton.tap()

        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'transactionRow.'")
        )
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        return [rows.element(boundBy: 0), rows.element(boundBy: 1)]
    }

    /// One selected transaction keeps the single-row bar; a second grows it
    /// into a card with the count and total.
    @MainActor
    func testBarGrowsIntoACardWithTheTotalForMultipleSelection() {
        let app = XCUIApplication()
        let rows = openAllAccountsSelecting(app)
        let summary = app.descendants(matching: .any)["transactionBulkBar.summary"]

        rows[0].tap()
        XCTAssertFalse(summary.waitForExistence(timeout: 1), "one selected transaction needs no summary")

        rows[1].tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "two selected transactions show the summary card")
        XCTAssertTrue(summary.label.contains("2 selected"), "the card shows how many are selected")
        XCTAssertTrue(summary.label.contains("Total"), "the card shows the total")
        XCTAssertTrue(app.buttons["transactionBulkBar.categorize"].isEnabled)
        XCTAssertTrue(app.buttons["transactionBulkBar.tag"].isEnabled)
        XCTAssertFalse(app.buttons["transactionBulkBar.merge"].exists,
                       "Merge is only offered for two transactions with the same account and amount")

        rows[1].tap()
        XCTAssertTrue(summary.waitForNonExistence(timeout: 5), "back to one selected, the card shrinks again")
    }

    @MainActor
    func testTagIsAddedToTheSelectedTransactions() {
        let app = XCUIApplication()
        let rows = openAllAccountsSelecting(app)
        rows[0].tap()
        rows[1].tap()

        app.buttons["transactionBulkBar.tag"].tap()
        let field = app.textFields["transactionTagPicker.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("batchtag")
        app.buttons["transactionTagPicker.add"].tap()

        let tagged = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'batchtag'"))
        XCTAssertTrue(tagged.firstMatch.waitForExistence(timeout: 10), "the new tag shows on the selected transactions")
        XCTAssertGreaterThanOrEqual(tagged.count, 2)
    }

    @MainActor
    func testCategorizeOpensThePickerForTheSelection() {
        let app = XCUIApplication()
        let rows = openAllAccountsSelecting(app)
        rows[0].tap()
        rows[1].tap()

        app.buttons["transactionBulkBar.categorize"].tap()
        let groceries = app.buttons["Groceries"].firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 5), "the category picker opens")
        groceries.tap()
        XCTAssertTrue(groceries.waitForNonExistence(timeout: 5), "picking a category applies it and closes the picker")
    }
}
