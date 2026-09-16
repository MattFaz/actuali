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

        app.tabBars.buttons["Accounts"].tap()
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

        editor.tap()
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
    func testNoteVisibilityCanBeHiddenShownAndPersistsAcrossRelaunch() throws {
        let app = openAccount("Chase Checking")
        let noteRow = app.buttons["accountNoteRow"]
        let toolbarOverflow = app.buttons["OverflowBarButtonItem"]

        XCTAssertTrue(toolbarOverflow.waitForExistence(timeout: 5), "toolbar overflow not shown")

        // The preference is stored in UserDefaults, so the test may start with
        // notes either visible or hidden from a previous run. Normalize to
        // visible first instead of assuming the menu contains "Hide Notes".
        let notesInitiallyVisible = noteRow.waitForExistence(timeout: 5)
        toolbarOverflow.tap()

        if notesInitiallyVisible {
            let hideNotes = app.buttons["Hide Notes"]
            XCTAssertTrue(hideNotes.waitForExistence(timeout: 5), "Hide Notes control not shown")
            hideNotes.tap()
        } else {
            let showNotes = app.buttons["Show Notes"]
            XCTAssertTrue(showNotes.waitForExistence(timeout: 5), "Show Notes control not shown")
            showNotes.tap()
            XCTAssertTrue(noteRow.waitForExistence(timeout: 5), "notes could not be restored before testing")

            // The menu closes after selecting an action; reopen it to perform
            // the actual hide step.
            toolbarOverflow.tap()
            let hideNotes = app.buttons["Hide Notes"]
            XCTAssertTrue(hideNotes.waitForExistence(timeout: 5), "Hide Notes control not shown after restore")
            hideNotes.tap()
        }

        XCTAssertTrue(noteRow.waitForNonExistence(timeout: 5), "note row did not hide")

        // Verify the opposite menu action is exposed while hidden.
        toolbarOverflow.tap()
        let showNotes = app.buttons["Show Notes"]
        XCTAssertTrue(showNotes.waitForExistence(timeout: 5), "Show Notes control not shown while notes are hidden")
        showNotes.tap()
        XCTAssertTrue(noteRow.waitForExistence(timeout: 5), "Show Notes did not restore the note")

        // Hide it once more so the persisted state we verify after relaunch is
        // unambiguously the hidden state.
        toolbarOverflow.tap()
        let hideNotesAgain = app.buttons["Hide Notes"]
        XCTAssertTrue(hideNotesAgain.waitForExistence(timeout: 5), "Hide Notes control not shown before relaunch")
        hideNotesAgain.tap()
        XCTAssertTrue(noteRow.waitForNonExistence(timeout: 5), "note row did not hide before relaunch")

        app.terminate()
        app.launch()
        app.tabBars.buttons["Accounts"].tap()
        let account = app.staticTexts["Chase Checking"].firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 10), "Chase Checking row not found after relaunch")
        account.tap()

        let relaunchedNoteRow = app.buttons["accountNoteRow"]
        let relaunchedToolbarOverflow = app.buttons["OverflowBarButtonItem"]
        XCTAssertTrue(relaunchedToolbarOverflow.waitForExistence(timeout: 5), "toolbar overflow not shown after relaunch")
        XCTAssertFalse(relaunchedNoteRow.waitForExistence(timeout: 2), "hidden note reappeared after relaunch")

        // Restore the user's preference after the persistence assertion so a
        // later test run starts from the normal visible state.
        relaunchedToolbarOverflow.tap()
        let relaunchedShowNotes = app.buttons["Show Notes"]
        XCTAssertTrue(relaunchedShowNotes.waitForExistence(timeout: 5), "Show Notes control not shown after relaunch")
        relaunchedShowNotes.tap()
        XCTAssertTrue(relaunchedNoteRow.waitForExistence(timeout: 5), "Show Notes did not restore the note after relaunch")
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
