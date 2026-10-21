import XCTest

final class AddTransactionNotesUITests: XCTestCase {
    @MainActor
    func testOptionalNotesRowsOnlyAppearWhenTheyHaveContent() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2"]
        app.launch()

        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))

        let notes = app.descendants(matching: .any)["addTransaction.notes"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        let save = app.buttons["Add Transaction"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))

        assertNoBlankRow(between: notes, and: save, "empty notes leave a blank row before Save")

        notes.tap()
        // One typing call: a second typeText without a fresh tap loses
        // keyboard focus on iOS 27.
        notes.typeText("Lunch #")
        assertNoBlankRow(between: notes, and: save, "plain notes leave a blank row before Save")
        let coffee = app.buttons["tagSuggestion-coffee"]
        XCTAssertTrue(coffee.waitForExistence(timeout: 5),
                      "# should show existing tags; field reads: \(notes.value as? String ?? "")")
        coffee.tap()
        XCTAssertTrue(coffee.waitForNonExistence(timeout: 5), "completing a tag should hide suggestions")
        XCTAssertEqual(notes.value as? String, "Lunch #coffee ")
        assertNoBlankRow(between: notes, and: save, "completed tags leave a blank row before Save")

        notes.tap()
        notes.typeText("#no-matching-tag")
        assertNoBlankRow(between: notes, and: save, "unmatched tags leave a blank row before Save")

        notes.typeText(" https://example.com/receipt")
        XCTAssertTrue(app.descendants(matching: .any)["noteLinkRow"].firstMatch.waitForExistence(timeout: 5),
                      "notes with a URL should still show a tappable link row")
    }

    @MainActor
    func testNotesClearButtonClearsText() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2"]
        app.launch()

        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))

        let notes = app.descendants(matching: .any)["addTransaction.notes"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        let clear = app.buttons["addTransaction.notesClear"]
        XCTAssertFalse(clear.exists, "clear button shouldn't exist when notes are empty")

        notes.tap()
        notes.typeText("Pending SMS receipt")
        XCTAssertTrue(clear.waitForExistence(timeout: 5))

        clear.tap()
        XCTAssertTrue(clear.waitForNonExistence(timeout: 5), "clear button should disappear once notes are empty")
    }

    @MainActor
    func testSplitLineNotesHaveNoEmptyLinkSpaceAndStillShowLinks() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2"]
        app.launch()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))

        app.buttons["Split into multiple categories"].tap()
        let notes = app.textFields["addTransaction.splitLine.notes"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        let row = app.cells.containing(.textField, identifier: "addTransaction.splitLine.notes").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(notes.frame.isEmpty)
        XCTAssertFalse(row.frame.isEmpty)
        let bottomPadding = row.frame.maxY - notes.frame.maxY
        XCTAssertGreaterThan(bottomPadding, 0)
        XCTAssertLessThan(bottomPadding, 16, "empty link previews add space below split notes")

        notes.tap()
        notes.typeText("https://example.com/receipt")
        XCTAssertTrue(app.descendants(matching: .any)["noteLinkRow"].firstMatch.waitForExistence(timeout: 5),
                      "split notes with a URL should still show a tappable link")
    }

    /// The split line's tag chips sit above its notes field, clear of the
    /// keyboard accessory that covers the row below it.
    @MainActor
    func testSplitLineTagSuggestionsAppearAboveTheField() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2"]
        app.launch()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))

        app.buttons["Split into multiple categories"].tap()
        let notes = app.textFields["addTransaction.splitLine.notes"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 5))

        notes.tap()
        notes.typeText("#")
        let coffee = app.buttons["tagSuggestion-coffee"]
        XCTAssertTrue(coffee.waitForExistence(timeout: 5),
                      "# shows the tag chips above the field; field reads: \(notes.value as? String ?? "")")
        XCTAssertLessThan(coffee.frame.maxY, notes.frame.minY,
                          "the chips must sit above the notes field, clear of the keyboard accessory")
        coffee.tap()
        XCTAssertEqual(notes.value as? String, "#coffee ")
    }

    /// GH #674: as the focused Notes field grows past the keyboard, the
    /// form has to scroll it back into view without a manual scroll.
    @MainActor
    func testNotesStaysAboveKeyboardWhileTyping() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2"]
        app.launch()

        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))

        let notes = app.descendants(matching: .any)["addTransaction.notes"].firstMatch
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        notes.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        assertAboveKeyboard(notes, in: app, "Notes is hidden once focused")
        let focusedTop = notes.frame.minY

        // Real key taps: typeText skips the change notification a keystroke
        // posts, and on iOS 27 it reads as a hardware keyboard, which
        // minimizes the software one.
        let text = "lunch with the whole team at the usual place downtown paid on the shared card and "
            + "split later with everyone who came along including the two new starters"
        for character in text {
            tapKey(character == " " ? "space" : String(character), in: app)
        }
        assertAboveKeyboard(notes, in: app, "Notes is hidden after it grows")
        XCTAssertLessThan(notes.frame.minY, focusedTop, "the form did not scroll Notes up as it grew")
    }

    /// Tap an on-screen key. The AX tree can also hold an off-screen copy of
    /// a key, which `.tap()` then refuses with an AX scroll error.
    @MainActor
    private func tapKey(_ key: String, in app: XCUIApplication) {
        // The keyboard starts shifted, so the first letter is a capital key.
        for candidate in [key, key.uppercased()] {
            if let onScreen = onScreenCopy(app.keys.matching(identifier: candidate)),
               onScreen.isHittable {
                onScreen.tap()
                return
            }
        }
        XCTFail("key \(key) is not reachable")
    }

    @MainActor
    private func assertAboveKeyboard(
        _ field: XCUIElement,
        in app: XCUIApplication,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // The scroll is animated; let it land before reading frames.
        Thread.sleep(forTimeInterval: 1)
        let keyboard = app.keyboards.firstMatch.frame
        XCTAssertLessThan(keyboard.minY, app.frame.maxY, "software keyboard is not on screen",
                          file: file, line: line)
        // The predictions bar sits on top of the keys and hides rows too.
        let assistant = app.otherElements["SystemInputAssistantView"]
        let keyboardTop = assistant.exists ? min(keyboard.minY, assistant.frame.minY) : keyboard.minY
        XCTAssertTrue(field.isHittable, message, file: file, line: line)
        XCTAssertLessThanOrEqual(field.frame.maxY, keyboardTop,
                                 "\(message): field bottom \(field.frame.maxY), keyboard top \(keyboardTop)",
                                 file: file, line: line)
    }

    @MainActor
    private func assertNoBlankRow(
        between notes: XCUIElement,
        and save: XCUIElement,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let notesFrame = notes.frame
        let saveFrame = save.frame
        XCTAssertFalse(notesFrame.isEmpty, "notes frame is empty: \(message)", file: file, line: line)
        XCTAssertFalse(saveFrame.isEmpty, "save frame is empty: \(message)", file: file, line: line)
        let gap = saveFrame.minY - notesFrame.maxY
        XCTAssertGreaterThan(gap, 0, message, file: file, line: line)
        // A one-line note needs only the normal row padding and section gap
        // before Save. An empty link-preview row adds another ~44 points.
        XCTAssertLessThan(gap, 60, message, file: file, line: line)
    }
}
