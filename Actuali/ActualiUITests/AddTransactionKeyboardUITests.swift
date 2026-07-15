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

        // The tab-hosted add flow is not a presentation; a Cancel button
        // here would be a no-op and must not render.
        XCTAssertFalse(app.navigationBars.buttons["Cancel"].exists,
                       "Cancel button rendered in the tab-hosted add flow")

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

        let cancel = app.navigationBars.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5),
                      "no Cancel button on the sheet-presented add flow")
        cancel.tap()

        XCTAssertTrue(addTitle.waitForNonExistence(timeout: 5),
                      "add sheet did not dismiss after tapping Cancel")
    }
}
