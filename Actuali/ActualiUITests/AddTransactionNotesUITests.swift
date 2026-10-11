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
        notes.typeText("Lunch ")
        assertNoBlankRow(between: notes, and: save, "plain notes leave a blank row before Save")
        notes.typeText("#")
        let coffee = app.buttons["tagSuggestion-coffee"]
        XCTAssertTrue(coffee.waitForExistence(timeout: 5), "# should show existing tags")
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
