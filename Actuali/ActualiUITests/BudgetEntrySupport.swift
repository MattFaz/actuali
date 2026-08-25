import XCTest

extension XCTestCase {
    /// Opens the category's edit-budget sheet and types a new amount.
    /// The amount field interprets bare digits as cents ("100" → 1.00).
    @MainActor
    func setBudget(_ app: XCUIApplication, category: String, centsKeystrokes: String) {
        let editButton = app.buttons["Edit budgeted amount for \(category)"]
        var scrollsLeft = 8
        while !editButton.isHittable && scrollsLeft > 0 {
            app.swipeUp()
            scrollsLeft -= 1
        }
        XCTAssertTrue(editButton.isHittable, "edit button for \(category) not reachable")
        editButton.tap()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "amount field not shown")
        // The sheet autofocuses the field; the decimal pad appearing is the
        // signal that it's ready. Enter the amount by tapping keypad keys —
        // typeText's focus-dependent event synthesis flakes on CI runners.
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10),
                      "keyboard did not appear for the amount field")
        // Keypad taps cost over a second each, so clear only what's there.
        // An empty field reports its placeholder as the value; deleting
        // those few phantom characters is a harmless no-op.
        let deleteKey = app.keys["Delete"]
        let existing = (field.value as? String) ?? ""
        for _ in 0..<min(existing.count, 10) { deleteKey.tap() }
        for digit in centsKeystrokes {
            app.keys[String(digit)].tap()
        }

        let saveButton = app.buttons["Save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Save button not shown")
        saveButton.tap()
        // Sheet dismissal returns us to the budget list.
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "edit sheet did not dismiss")
    }
}
