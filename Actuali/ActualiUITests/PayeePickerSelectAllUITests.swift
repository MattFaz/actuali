import XCTest

/// GH #486: reopening the payee picker for a transaction that already has a
/// payee pre-fills the search field with the old name. The whole string must
/// be selected so the first keystroke replaces it instead of appending to it.
final class PayeePickerSelectAllUITests: XCTestCase {

    @MainActor
    func testTypingReplacesPrefilledPayeeName() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2"]
        app.launch()

        let payeeRow = app.buttons["addTransaction.payee"]
        XCTAssertTrue(payeeRow.waitForExistence(timeout: 10), "payee row not found")
        payeeRow.tap()

        // Pick an existing payee so the picker reopens with the name pre-filled.
        let blueBottle = app.buttons.matching(
            NSPredicate(format: "label == 'Blue Bottle Coffee'")
        ).firstMatch
        XCTAssertTrue(blueBottle.waitForExistence(timeout: 5), "Blue Bottle Coffee row not found")
        blueBottle.tap()
        XCTAssertTrue(blueBottle.waitForNonExistence(timeout: 5), "picker sheet did not close")

        payeeRow.tap()
        let searchField = app.textFields.matching(
            NSPredicate(format: "placeholderValue == 'Search payees'")
        ).firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "payee picker did not reopen")
        XCTAssertEqual(searchField.value as? String, "Blue Bottle Coffee",
                       "picker should reopen pre-filled with the current payee")

        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "keyboard did not come up for the pre-filled search field")
        searchField.typeText("x")
        XCTAssertEqual(searchField.value as? String, "x",
                       "typing should overwrite the pre-filled payee, not append to it")

        // Scrolling dismisses the keyboard; re-focusing must not re-select-all,
        // or the next keystroke would wipe the query the user already typed.
        app.swipeUp()
        searchField.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "keyboard did not come back for the refocused field")
        XCTAssertEqual(searchField.value as? String, "x",
                       "refocusing must not wipe the query")
        searchField.typeText("y")
        let refocusedValue = (searchField.value as? String) ?? ""
        XCTAssertTrue(["xy", "yx"].contains(refocusedValue),
                      "after refocus the keystroke should append (got \(refocusedValue); "
                      + "\"y\" alone means re-select-all)")
    }
}
