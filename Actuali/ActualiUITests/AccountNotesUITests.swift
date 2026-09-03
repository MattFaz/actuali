import XCTest

/// End-to-end check for account notes (GH #198).
///
/// The demo budget's seeded Chase Checking note must be visible on the account
/// detail view without any digging — the same treatment a category's note gets
/// — and an edit typed into the app must come back on the row after saving,
/// proving the read, the write and the refresh are wired together.
final class AccountNotesUITests: XCTestCase {

    @MainActor
    private func openAccount(_ name: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()

        app.tabBars.buttons["tab.accounts"].tap()
        let account = app.staticTexts[name].firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 10), "\(name) row not found")
        account.tap()
        return app
    }

    @MainActor
    func testViewsAndEditsAccountNote() throws {
        let app = openAccount("Chase Checking")

        // The note shows on the detail view, above the transactions.
        let noteRow = app.buttons["accountNoteRow"]
        XCTAssertTrue(noteRow.waitForExistence(timeout: 10), "note row not shown")
        XCTAssertTrue(noteRow.label.contains("Direct deposit"),
                      "seeded note not displayed, row read: \(noteRow.label)")
        attachScreenshot(app, name: "1-account-note")

        // Tapping opens the editor, already focused so typing lands in it.
        noteRow.tap()
        let editor = app.textViews["noteEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "note editor not shown")
        attachScreenshot(app, name: "2-account-note-editor")

        editor.typeText("checked")

        let save = app.buttons["saveNote"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), "Save button not shown")
        save.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 10), "note editor did not dismiss")

        // The edit is reflected on the row, and the original text survives —
        // this is an edit, not a replacement (cursor position is the
        // keyboard's business, so only containment is asserted).
        let updated = app.buttons["accountNoteRow"]
        XCTAssertTrue(updated.waitForExistence(timeout: 10), "note row gone after save")
        XCTAssertTrue(updated.label.contains("checked"),
                      "typed text missing after save, row read: \(updated.label)")
        XCTAssertTrue(updated.label.contains("Direct deposit"),
                      "original note lost on save, row read: \(updated.label)")
        attachScreenshot(app, name: "3-account-note-edited")
    }

    /// An account nobody has annotated offers "Add Note" rather than a blank
    /// row — and rather than hiding, which is reserved for files whose schema
    /// can't store notes at all.
    @MainActor
    func testUnannotatedAccountOffersAddNote() throws {
        let app = openAccount("Ally Savings")

        let noteRow = app.buttons["accountNoteRow"]
        XCTAssertTrue(noteRow.waitForExistence(timeout: 10), "note row not shown")
        XCTAssertTrue(noteRow.label.contains("Add Note"),
                      "empty note did not offer Add Note, row read: \(noteRow.label)")
        attachScreenshot(app, name: "4-account-add-note")
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
