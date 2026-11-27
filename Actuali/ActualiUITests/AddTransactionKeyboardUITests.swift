import XCTest

/// Repro for the "can't back out of Add Transaction" report (actios-j4nn).
///
/// Focusing the amount field brought up the decimal pad with no Done bar:
/// the SwiftUI keyboard toolbar only attaches to SwiftUI text fields, and
/// AmountInputField is a UIKit-backed UITextField. The decimal pad has no
/// return key and covers the tab bar, so there was no way out. The
/// sheet-presented add flow (account detail "+", notification prefill) also
/// had no Cancel button — only the edit flow did.
final class AddTransactionKeyboardUITests: XCTestCase {
    @MainActor
    func testAmountFieldShowsDoneBarAndDismissesKeyboard() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2"]
        app.launch()

        let amountField = app.textFields.matching(
            NSPredicate(format: "placeholderValue == '0.00'")
        ).firstMatch
        XCTAssertTrue(amountField.waitForExistence(timeout: 10), "amount field not found")

        amountField.tap()
        XCTAssertTrue(app.amountKeypad.waitForExistence(timeout: 5),
                      "keyboard did not appear")

        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5),
                      "no Done key on the amount keypad")
        // GH #746: Done must stay on screen even on a 375pt phone (iPhone
        // 13 mini, SE).
        XCTAssertLessThanOrEqual(
            done.frame.maxX, app.windows.firstMatch.frame.maxX,
            "Done runs past the screen edge: done=\(done.frame)"
        )
        done.tap()

        XCTAssertTrue(app.amountKeypad.waitForNonExistence(timeout: 5),
                      "keyboard did not dismiss after tapping Done")

        // With the keyboard gone the tab bar is reachable again — the
        // reporter's actual goal was backing out to another tab.
        XCTAssertTrue(app.tabBars.buttons["Accounts"].isHittable,
                      "tab bar not reachable after dismissing the keyboard")
    }

    /// The operators sit on the keypad as one-tap keys.
    @MainActor
    func testOperatorKeyInsertsOperator() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let amountField = app.textFields.matching(
            NSPredicate(format: "placeholderValue == '0.00'")
        ).firstMatch
        XCTAssertTrue(amountField.waitForExistence(timeout: 10), "amount field not found")
        XCTAssertTrue(app.amountKeypad.waitForExistence(timeout: 10),
                      "keyboard did not appear")
        amountField.typeText("12")

        // "Add" would also match the Add tab, so use an unambiguous key.
        let multiply = app.buttons["Multiply"]
        XCTAssertTrue(multiply.waitForExistence(timeout: 5), "no operator keys on the keypad")
        multiply.tap()
        amountField.typeText("3")

        let expression = NSPredicate(format: "value CONTAINS '×'")
        expectation(for: expression, evaluatedWith: amountField)
        waitForExpectations(timeout: 5)
    }

    /// The floating save button steps aside while the keypad is up, where
    /// it would cover the form's last rows, and returns after Done.
    @MainActor
    func testSaveButtonHidesWhileTheKeypadIsUp() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        XCTAssertTrue(app.amountKeypad.waitForExistence(timeout: 10), "keypad did not come up")
        XCTAssertFalse(app.buttons["addTransaction.save"].exists, "save button showing over the keypad")

        app.buttons["Done"].tap()
        XCTAssertTrue(app.amountKeypad.waitForNonExistence(timeout: 5), "keypad did not dismiss")
        XCTAssertTrue(app.buttons["addTransaction.save"].waitForExistence(timeout: 5),
                      "save button did not return after Done")
    }

    /// The add flow autofocuses the amount field — the first thing anyone
    /// enters — so the keyboard must come up without a tap and keypad input
    /// must land in that field.
    @MainActor
    func testAddTabAutofocusesAmountField() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2"]
        app.launch()

        XCTAssertTrue(app.amountKeypad.waitForExistence(timeout: 10),
                      "keyboard did not come up on its own for the amount field")

        let amountField = app.textFields.matching(
            NSPredicate(format: "placeholderValue == '0.00'")
        ).firstMatch
        XCTAssertTrue(amountField.exists, "amount field not found")

        app.keys["5"].tap()
        XCTAssertEqual(amountField.value as? String, "0.05",
                       "keypad input did not land in the amount field")
    }

    /// The add form stays alive while another tab is selected, so selecting
    /// Add again must issue a fresh focus request even when the amount has
    /// already been started.
    @MainActor
    func testReturningToAddTabRefocusesAmountField() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2"]
        app.launch()

        let amountField = app.textFields.matching(
            NSPredicate(format: "placeholderValue == '0.00'")
        ).firstMatch
        XCTAssertTrue(amountField.waitForExistence(timeout: 10), "amount field not found")
        XCTAssertTrue(app.amountKeypad.waitForExistence(timeout: 10),
                      "keyboard did not come up on the initial Add tab")
        app.keys["5"].tap()
        XCTAssertEqual(amountField.value as? String, "0.05")

        app.buttons["Done"].tap()
        XCTAssertTrue(app.amountKeypad.waitForNonExistence(timeout: 5))
        app.tabBars.buttons["Accounts"].tap()

        app.tabBars.buttons["Add"].tap()
        XCTAssertTrue(app.amountKeypad.waitForExistence(timeout: 10),
                      "keyboard did not return when Add was selected again")
        XCTAssertEqual(amountField.value as? String, "0.05",
                       "returning to Add should preserve the partial amount")
    }

    @MainActor
    func testCategoryPickerAutofocusesSearchField() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2"]
        app.launch()

        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "amount keyboard did not appear")
        done.tap()
        XCTAssertTrue(app.amountKeypad.waitForNonExistence(timeout: 5),
                      "amount keyboard did not dismiss")

        let categoryRow = app.buttons["addTransaction.category"]
        XCTAssertTrue(categoryRow.waitForExistence(timeout: 5), "category row not found")
        categoryRow.tap()

        let searchField = app.textFields["categoryPicker.search"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5),
                      "category search field not found")
        XCTAssertLessThan(searchField.frame.height, 60,
                          "category search field should remain a compact top bar")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "category search field did not autofocus")
    }

    @MainActor
    func testReturningFromCategoryPickerDoesNotRefocusAmountField() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2"]
        app.launch()

        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "amount keyboard did not appear")
        done.tap()
        XCTAssertTrue(app.amountKeypad.waitForNonExistence(timeout: 5),
                      "amount keyboard did not dismiss")

        let categoryRow = app.buttons["addTransaction.category"]
        XCTAssertTrue(categoryRow.waitForExistence(timeout: 5), "category row not found")
        categoryRow.tap()

        let searchField = app.textFields["categoryPicker.search"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5),
                      "category search field not found")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "category search field did not autofocus")

        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "category picker back button not found")
        back.tap()
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 5),
                      "category picker did not dismiss")
        XCTAssertTrue(app.amountKeypad.waitForNonExistence(timeout: 5),
                      "amount keyboard reopened after leaving category picker")
    }

    /// GH #558: with the amount still focused, opening a picker left UIKit
    /// holding the amount field as the responder to restore, so coming back
    /// brought the decimal pad up again with the amount selected.
    @MainActor
    func testPickingPayeeWithAmountFocusedLeavesKeyboardDown() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2"]
        app.launch()

        XCTAssertTrue(app.amountKeypad.waitForExistence(timeout: 10),
                      "amount keyboard did not appear")
        app.keys["5"].tap()

        let payeeRow = app.buttons["addTransaction.payee"]
        XCTAssertTrue(payeeRow.waitForExistence(timeout: 5), "payee row not found")
        payeeRow.tap()

        let blueBottle = app.buttons.matching(
            NSPredicate(format: "label == 'Blue Bottle Coffee'")
        ).firstMatch
        XCTAssertTrue(blueBottle.waitForExistence(timeout: 5), "Blue Bottle Coffee row not found")
        blueBottle.tap()
        XCTAssertTrue(blueBottle.waitForNonExistence(timeout: 5), "picker sheet did not close")

        XCTAssertTrue(app.amountKeypad.waitForNonExistence(timeout: 5),
                      "amount keyboard reopened after picking a payee")
    }

    @MainActor
    func testPickingCategoryWithAmountFocusedLeavesKeyboardDown() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2"]
        app.launch()

        XCTAssertTrue(app.amountKeypad.waitForExistence(timeout: 10),
                      "amount keyboard did not appear")
        app.keys["5"].tap()

        let categoryRow = app.buttons["addTransaction.category"]
        XCTAssertTrue(categoryRow.waitForExistence(timeout: 5), "category row not found")
        categoryRow.tap()

        let searchField = app.textFields["categoryPicker.search"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5),
                      "category search field not found")
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "category picker back button not found")
        back.tap()
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 5),
                      "category picker did not dismiss")

        XCTAssertTrue(app.amountKeypad.waitForNonExistence(timeout: 5),
                      "amount keyboard reopened after leaving category picker")
    }

    /// Split lines open their category picker as a sheet from a separate
    /// row view, so they need their own coverage.
    @MainActor
    func testPickingSplitLineCategoryWithAmountFocusedLeavesKeyboardDown() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2"]
        app.launch()

        XCTAssertTrue(app.amountKeypad.waitForExistence(timeout: 10),
                      "amount keyboard did not appear")
        app.keys["5"].tap()

        let split = app.buttons["Split into multiple categories"]
        XCTAssertTrue(split.waitForExistence(timeout: 5), "split button not found")
        split.tap()

        let lineCategory = app.buttons["addTransaction.splitLine.category"].firstMatch
        XCTAssertTrue(lineCategory.waitForExistence(timeout: 5), "split line category not found")
        XCTAssertTrue(app.amountKeypad.exists,
                      "amount should still be focused when the split line picker opens")
        lineCategory.tap()

        let groceries = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Groceries'")
        ).firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 5), "Groceries row not found")
        groceries.tap()
        XCTAssertTrue(app.textFields["categoryPicker.search"].waitForNonExistence(timeout: 5),
                      "split line category picker did not dismiss")

        XCTAssertTrue(app.amountKeypad.waitForNonExistence(timeout: 5),
                      "amount keyboard reopened after picking a split line category")
    }

    @MainActor
    func testPickingSplitLinePayeeWithAmountFocusedLeavesKeyboardDown() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2"]
        app.launch()

        XCTAssertTrue(app.amountKeypad.waitForExistence(timeout: 10),
                      "amount keyboard did not appear")
        app.keys["5"].tap()

        let split = app.buttons["Split into multiple categories"]
        XCTAssertTrue(split.waitForExistence(timeout: 5), "split button not found")
        split.tap()

        let linePayee = app.buttons["addTransaction.splitLine.payee"].firstMatch
        XCTAssertTrue(linePayee.waitForExistence(timeout: 5), "split line payee not found")
        XCTAssertTrue(app.amountKeypad.exists,
                      "amount should still be focused when the split line picker opens")
        linePayee.tap()

        let blueBottle = app.buttons.matching(
            NSPredicate(format: "label == 'Blue Bottle Coffee'")
        ).firstMatch
        XCTAssertTrue(blueBottle.waitForExistence(timeout: 5), "Blue Bottle Coffee row not found")
        blueBottle.tap()
        // The line's own button now reads "Blue Bottle Coffee", so wait on
        // the picker's search field instead.
        let search = app.textFields.matching(
            NSPredicate(format: "placeholderValue == 'Search payees'")
        ).firstMatch
        XCTAssertTrue(search.waitForNonExistence(timeout: 5), "picker sheet did not close")

        XCTAssertTrue(app.amountKeypad.waitForNonExistence(timeout: 5),
                      "amount keyboard reopened after picking a split line payee")
    }

    @MainActor
    func testSheetPresentedAddFlowShowsCancel() {
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

        // The sheet autofocuses the amount field, and Cancel is a row at the
        // foot of the form now — drop the keyboard first, then reach it.
        if app.amountKeypad.waitForExistence(timeout: 5) {
            app.buttons["Done"].tap()
        }

        let close = app.buttons["addTransaction.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5),
                      "no close button on the sheet-presented add flow")
        close.tap()

        XCTAssertTrue(addSheet.waitForNonExistence(timeout: 5),
                      "add sheet did not dismiss after tapping close")
    }
}
