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

        // A loaded runner can still be settling the sheet when the first keys
        // land, and the presentation then puts the category's original amount
        // back over what was typed — Save commits the old value and the test
        // fails somewhere later (nightly run 32860255135). Read the field back
        // and retype rather than trusting the taps.
        var entered = false
        for _ in 0..<3 where !entered {
            clearAmount(app, field: field)
            for digit in centsKeystrokes {
                app.keys[String(digit)].tap()
            }
            entered = waitForDigits(centsKeystrokes, in: field)
        }
        XCTAssertTrue(entered,
                      "amount field reads \((field.value as? String) ?? "") after typing \(centsKeystrokes)")

        let saveButton = app.buttons["Save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Save button not shown")
        saveButton.tap()
        // Sheet dismissal returns us to the budget list.
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "edit sheet did not dismiss")
    }

    /// Keypad taps cost over a second each, so delete only what's there — an
    /// empty field reports its "0.00" placeholder as the value.
    @MainActor
    private func clearAmount(_ app: XCUIApplication, field: XCUIElement) {
        let deleteKey = app.keys["Delete"]
        var deletesLeft = 12
        while !digits(of: field).allSatisfy({ $0 == "0" }) && deletesLeft > 0 {
            deleteKey.tap()
            deletesLeft -= 1
        }
    }

    /// Digits only, so "1.00" and "1,000.00" compare cleanly against the
    /// keystrokes that produced them whatever the locale's separators are.
    @MainActor
    private func digits(of field: XCUIElement) -> String {
        ((field.value as? String) ?? "").filter(\.isNumber)
    }

    @MainActor
    private func waitForDigits(_ expected: String, in field: XCUIElement,
                               timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if digits(of: field) == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return false
    }
}
