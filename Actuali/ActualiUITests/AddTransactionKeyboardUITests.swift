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
    func testAmountFieldShowsDoneBarAndDismissesKeyboard() throws {
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

        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5),
                      "no Done button above the decimal pad for the amount field")
        done.tap()

        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5),
                      "keyboard did not dismiss after tapping Done")

        // With the keyboard gone the tab bar is reachable again — the
        // reporter's actual goal was backing out to another tab.
        XCTAssertTrue(app.tabBars.buttons["Accounts"].isHittable,
                      "tab bar not reachable after dismissing the keyboard")
    }

    /// The add flow autofocuses the amount field — the first thing anyone
    /// enters — so the keyboard must come up without a tap and keypad input
    /// must land in that field.
    @MainActor
    func testAddTabAutofocusesAmountField() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2"]
        app.launch()

        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10),
                      "keyboard did not come up on its own for the amount field")

        let amountField = app.textFields.matching(
            NSPredicate(format: "placeholderValue == '0.00'")
        ).firstMatch
        XCTAssertTrue(amountField.exists, "amount field not found")

        app.keys["5"].tap()
        XCTAssertEqual(amountField.value as? String, "0.05",
                       "keypad input did not land in the amount field")
    }

    @MainActor
    func testSheetPresentedAddFlowShowsCancel() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "0"]
        app.launch()

        let accountRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Chase Checking'")
        ).firstMatch
        XCTAssertTrue(accountRow.waitForExistence(timeout: 10), "Chase Checking row not found")
        accountRow.tap()

        let addButton = app.navigationBars.buttons["Add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5), "'+' toolbar button not found")
        addButton.tap()

        let addTitle = app.navigationBars["Add Transaction"]
        XCTAssertTrue(addTitle.waitForExistence(timeout: 5), "add sheet did not present")

        // The sheet autofocuses the amount field, and Cancel is a row at the
        // foot of the form now — drop the keyboard first, then reach it.
        if app.keyboards.firstMatch.waitForExistence(timeout: 5) {
            app.buttons["Done"].tap()
        }

        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5),
                      "no Cancel button on the sheet-presented add flow")
        var scrollsLeft = 5
        while !cancel.isHittable && scrollsLeft > 0 {
            app.swipeUp()
            scrollsLeft -= 1
        }
        cancel.tap()

        XCTAssertTrue(addTitle.waitForNonExistence(timeout: 5),
                      "add sheet did not dismiss after tapping Cancel")
    }
}
