import XCTest

/// The tap-to-edit flow for card mappings (issue #450): tapping a mapping row
/// must open the sheet in edit mode, pre-filled with the existing keyword and
/// target account, and saving must update the mapping in place.
final class CardMappingEditUITests: XCTestCase {

    @MainActor
    private func openCardMappings(in app: XCUIApplication) {
        let automationRow = app.buttons["Transactions & Automation"]
        XCTAssertTrue(automationRow.waitForExistence(timeout: 10),
                      "Transactions & Automation row not found")
        automationRow.tap()

        let mappingsRow = app.buttons["Card & Account Mappings"]
        XCTAssertTrue(mappingsRow.waitForExistence(timeout: 5),
                      "Card & Account Mappings row not found")
        mappingsRow.tap()
        XCTAssertTrue(app.navigationBars["Card Mappings"].waitForExistence(timeout: 5),
                      "Card Mappings screen did not open")
    }

    /// Creates a mapping through the add sheet. The demo budget has no default
    /// account, so the sheet seeds the first open account (Chase Checking).
    @MainActor
    private func addMapping(_ keyword: String, in app: XCUIApplication) {
        app.buttons["Add Card Mapping"].tap()

        let field = app.textFields["cardMappings.keywordField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "keyword field not found")
        field.tap()
        field.typeText(keyword)

        app.buttons["Save"].tap()

        let row = app.buttons["cardMappings.row.\(keyword)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "created mapping row not found")
        XCTAssertTrue(app.staticTexts["Routes to Chase Checking"].exists,
                      "new mapping should route to the first open demo account")
    }

    @MainActor
    func testTappingRowOpensEditSheetPrefilledAndSavingUpdatesTarget() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "4"]
        app.launch()
        openCardMappings(in: app)
        addMapping("1234", in: app)

        // Tap the row: the sheet must open in edit mode, pre-filled.
        app.buttons["cardMappings.row.1234"].tap()
        XCTAssertTrue(app.navigationBars["Edit Mapping"].waitForExistence(timeout: 5),
                      "tapping a mapping row did not open the edit sheet")
        let field = app.textFields["cardMappings.keywordField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "edit sheet has no keyword field")
        XCTAssertEqual(field.value as? String, "1234",
                       "edit sheet did not pre-fill the keyword")

        // Retarget the mapping and save: the list row must reflect the change.
        app.buttons["cardMappings.accountPicker"].tap()
        let ally = app.buttons["Ally Savings"].exists
            ? app.buttons["Ally Savings"]
            : app.staticTexts["Ally Savings"]
        XCTAssertTrue(ally.waitForExistence(timeout: 5), "account option not shown")
        ally.tap()

        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Routes to Ally Savings"].waitForExistence(timeout: 5),
                      "saving the edit did not retarget the mapping")
    }
}
