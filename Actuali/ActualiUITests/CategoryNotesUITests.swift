import XCTest

/// End-to-end check for category notes (GH #131).
///
/// The demo budget's seeded Groceries note must be visible on the category
/// detail view without any digging, and an edit typed into the app must come
/// back on the row after saving — proving the read, the write and the refresh
/// are wired together, not just individually correct.
final class CategoryNotesUITests: XCTestCase {

    @MainActor
    func testViewsAndEditsCategoryNote() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-budgetDisplayStyle", "clean", "-initialTab", "1"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Budget"].waitForExistence(timeout: 10),
                      "Budget tab not found")

        // Groceries is the demo category that ships annotated. The spent pill
        // opens the transactions view (#243 repurposed the name button for
        // category details); its label ends with the current month.
        let groceries = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Transactions for Groceries in'")
        ).firstMatch
        var scrollsLeft = 8
        while !groceries.isHittable && scrollsLeft > 0 {
            app.swipeUp()
            scrollsLeft -= 1
        }
        XCTAssertTrue(groceries.isHittable, "Groceries row not reachable")
        groceries.tap()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5),
                      "Groceries transactions did not open")

        // The note shows on the detail view, above the transactions.
        let noteRow = app.buttons["categoryNoteRow"]
        XCTAssertTrue(noteRow.waitForExistence(timeout: 5), "note row not shown")
        XCTAssertTrue(noteRow.label.contains("Target $650"),
                      "seeded note not displayed, row read: \(noteRow.label)")
        attachScreenshot(app, name: "1-category-note")

        // Tapping opens the editor, already focused so typing lands in it.
        noteRow.tap()
        let editor = app.textViews["noteEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "note editor not shown")
        attachScreenshot(app, name: "2-note-editor")

        editor.typeText("checked")

        let save = app.buttons["saveNote"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "Save button not shown")
        save.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "note editor did not dismiss")

        // The edit is reflected on the row, and the original text survives —
        // this is an edit, not a replacement (cursor position is the
        // keyboard's business, so only containment is asserted).
        let updated = app.buttons["categoryNoteRow"]
        XCTAssertTrue(updated.waitForExistence(timeout: 5), "note row gone after save")
        XCTAssertTrue(updated.label.contains("checked"),
                      "typed text missing after save, row read: \(updated.label)")
        XCTAssertTrue(updated.label.contains("Target $650"),
                      "original note lost on save, row read: \(updated.label)")
        attachScreenshot(app, name: "3-note-edited")
    }

    /// A category nobody has annotated offers "Add Note" rather than a blank
    /// row — and rather than hiding, which is reserved for files whose schema
    /// can't store notes at all.
    @MainActor
    func testUnannotatedCategoryOffersAddNote() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-budgetDisplayStyle", "clean", "-initialTab", "1"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Budget"].waitForExistence(timeout: 10),
                      "Budget tab not found")

        let rent = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Transactions for Rent in'")
        ).firstMatch
        var scrollsLeft = 8
        while !rent.isHittable && scrollsLeft > 0 {
            app.swipeUp()
            scrollsLeft -= 1
        }
        XCTAssertTrue(rent.isHittable, "Rent row not reachable")
        rent.tap()
        XCTAssertTrue(app.navigationBars["Rent"].waitForExistence(timeout: 5),
                      "Rent transactions did not open")

        let noteRow = app.buttons["categoryNoteRow"]
        XCTAssertTrue(noteRow.waitForExistence(timeout: 5), "note row not shown")
        XCTAssertTrue(noteRow.label.contains("Add Note"),
                      "empty note did not offer Add Note, row read: \(noteRow.label)")
        attachScreenshot(app, name: "4-add-note")
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
