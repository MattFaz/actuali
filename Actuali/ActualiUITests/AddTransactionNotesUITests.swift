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

        // A one-line note needs only the normal row padding and section gap
        // before Save. An empty link-preview row adds another ~44 points.
        XCTAssertLessThan(save.frame.minY - notes.frame.maxY, 60,
                          "empty notes leave a blank row before Save")

        notes.tap()
        notes.typeText("Lunch ")
        XCTAssertLessThan(save.frame.minY - notes.frame.maxY, 60,
                          "plain notes leave a blank row before Save")
        notes.typeText("#")
        let coffee = app.buttons["tagSuggestion-coffee"]
        XCTAssertTrue(coffee.waitForExistence(timeout: 5), "# should show existing tags")
        coffee.tap()
        XCTAssertTrue(coffee.waitForNonExistence(timeout: 5), "completing a tag should hide suggestions")
        XCTAssertEqual(notes.value as? String, "Lunch #coffee ")
        XCTAssertLessThan(save.frame.minY - notes.frame.maxY, 60,
                          "completed tags leave a blank row before Save")

        notes.tap()
        notes.typeText("#no-matching-tag")
        XCTAssertLessThan(save.frame.minY - notes.frame.maxY, 60,
                          "unmatched tags leave a blank row before Save")

        notes.typeText(" https://example.com/receipt")
        XCTAssertTrue(app.descendants(matching: .any)["noteLinkRow"].firstMatch.waitForExistence(timeout: 5),
                      "notes with a URL should still show a tappable link row")
    }
}
