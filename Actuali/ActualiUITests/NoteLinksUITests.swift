import XCTest

/// End-to-end check for tappable links in notes (GH #190).
///
/// The demo budget seeds Dining Out with a markdown link. The category detail
/// row must render the link's label (not raw markdown), tapping the link must
/// leave the app for the URL, and a plain-text tap must still open the editor
/// — proving links and the edit gesture coexist on one row.
final class NoteLinksUITests: XCTestCase {

    @MainActor
    func testCategoryNoteRendersTappableLink() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-budgetDisplayStyle", "clean", "-initialTab", "1"]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Budget"].waitForExistence(timeout: 10),
                      "Budget tab not found")

        // The spent pill opens the transactions view (#243 repurposed the
        // name button for category details); its label ends with the month.
        let dining = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Transactions for Dining Out in'")
        ).firstMatch
        var scrollsLeft = 8
        while !dining.isHittable && scrollsLeft > 0 {
            app.swipeUp()
            scrollsLeft -= 1
        }
        XCTAssertTrue(dining.isHittable, "Dining Out row not reachable")
        dining.tap()
        XCTAssertTrue(app.navigationBars["Dining Out"].waitForExistence(timeout: 5),
                      "Dining Out transactions did not open")

        let noteRow = app.buttons["categoryNoteRow"]
        XCTAssertTrue(noteRow.waitForExistence(timeout: 5), "note row not shown")
        // The markdown renders as its label, not as raw syntax.
        XCTAssertTrue(noteRow.label.contains("Rewards portal"),
                      "link label missing, row read: \(noteRow.label)")
        XCTAssertFalse(noteRow.label.contains("https://"),
                       "raw markdown leaked into the row: \(noteRow.label)")

        // A tap on the plain-text part of the row (line 1 — the link sits on
        // line 2) still opens the editor: links must not cost the row its
        // tap-to-edit.
        noteRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        let editor = app.textViews["noteEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "note editor did not open")

        // The editor surfaces the draft's link as a tappable row beneath the
        // text, since the editable text itself can't be tapped as a link.
        // SwiftUI exposes a Link in a Form row as different element types
        // across supported iOS versions, so the identifier is the contract.
        XCTAssertTrue(app.descendants(matching: .any)["noteLinkRow"].waitForExistence(timeout: 5),
                      "link row missing from note editor")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "editor did not dismiss")

        // Tapping the link itself leaves the app for the URL instead of
        // opening the editor.
        if #available(iOS 26, *) {
            let link = app.links["Rewards portal"]
            XCTAssertTrue(link.waitForExistence(timeout: 5), "inline link not exposed")
            link.tap()
        } else {
            let link = app.descendants(matching: .any)["categoryNoteLink.0"]
            XCTAssertTrue(link.waitForExistence(timeout: 5), "inline link not exposed")
            // The iOS 18 accessibility representation makes the link
            // discoverable, while the visual attributed text owns its tap.
            noteRow.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.75)).tap()
        }
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 10),
                      "tapping the note link did not open the URL")
    }
}
