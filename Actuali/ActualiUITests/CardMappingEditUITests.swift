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
    private func typeText(_ text: String, into field: XCUIElement, in app: XCUIApplication) {
        // On iOS 26+ the tap on a sheet's text field intermittently fails to
        // make it first responder, and a follow-up typeText dies with
        // "Neither element nor any descendant has keyboard focus". The
        // software keyboard is the focus signal: re-tap until it shows.
        for attempt in 1...3 {
            if app.keyboards.firstMatch.exists { break }
            if attempt > 1 {
                field.tap()
            }
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(app.keyboards.firstMatch.exists,
                      "keyboard did not appear after tapping \(field.identifier.isEmpty ? "field" : field.identifier)")
        field.typeText(text)
    }

    @MainActor
    private func addMapping(_ keyword: String, in app: XCUIApplication) {
        app.buttons["Add Card Mapping"].tap()

        let field = app.textFields["cardMappings.keywordField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "keyword field not found")
        field.tap()
        typeText(keyword, into: field, in: app)
        let saveButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Save'")).firstMatch
        _ = saveButton.waitForExistence(timeout: 5)
        let savePredicate = NSPredicate(format: "isEnabled == true")
        let expectation = XCTNSPredicateExpectation(predicate: savePredicate, object: saveButton)
        let result = XCTWaiter.wait(for: [expectation], timeout: 5)
        XCTAssertEqual(result, .completed, "Save button should be enabled after entering keyword and account")

        saveButton.tap()
        XCTAssertTrue(app.navigationBars["Add Mapping"].waitForNonExistence(timeout: 5),
                      "add sheet did not dismiss after save")

        let row = app.buttons["cardMappings.row.\(keyword)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "created mapping row not found")
        XCTAssertTrue(row.staticTexts["Chase Checking"].exists,
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
        XCTAssertTrue(app.navigationBars["Edit Mapping"].waitForNonExistence(timeout: 5),
                      "edit sheet did not dismiss after save")
        let updatedRow = app.buttons["cardMappings.row.1234"]
        XCTAssertTrue(updatedRow.waitForExistence(timeout: 5), "mapping row not found after save")
        XCTAssertTrue(updatedRow.staticTexts["Ally Savings"].exists,
                      "saving the edit did not retarget the mapping")
    }

    @MainActor
    func testAddingAndRemovingMultipleKeywords() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "4"]
        app.launch()
        openCardMappings(in: app)

        app.buttons["Add Card Mapping"].tap()
        XCTAssertTrue(app.navigationBars["Add Mapping"].waitForExistence(timeout: 5), "add sheet did not open")
        let firstField = app.textFields["cardMappings.keywordField"]
        XCTAssertTrue(firstField.waitForExistence(timeout: 5), "keyword field not found")
        XCTAssertTrue(firstField.isHittable, "keyword field is not hittable")
        firstField.tap()
        typeText("246813", into: firstField, in: app)
        let firstValue = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == '246813'"), object: firstField
        )
        XCTAssertEqual(XCTWaiter.wait(for: [firstValue], timeout: 5), .completed)
        app.buttons["cardMappings.addKeywordButton"].tap()
        let secondField = app.textFields["cardMappings.keywordField.1"]
        XCTAssertTrue(secondField.waitForExistence(timeout: 5), "second keyword field not found")
        XCTAssertTrue(secondField.isHittable, "second keyword field is not hittable")
        secondField.tap()
        typeText("975310", into: secondField, in: app)
        let secondValue = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == '975310'"), object: secondField
        )
        XCTAssertEqual(XCTWaiter.wait(for: [secondValue], timeout: 5), .completed)
        let removeButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'cardMappings.removeKeyword.'")
        )
        let removeSecond = removeButtons.element(boundBy: 1)
        XCTAssertTrue(removeSecond.waitForExistence(timeout: 5), "second keyword remove button not found")
        removeSecond.tap()
        XCTAssertTrue(secondField.waitForNonExistence(timeout: 5), "removed keyword field is still present")
        app.buttons["cardMappings.addKeywordButton"].tap()
        let replacementField = app.textFields["cardMappings.keywordField.1"]
        XCTAssertTrue(replacementField.waitForExistence(timeout: 5), "replacement keyword field not found")
        XCTAssertTrue(replacementField.isHittable, "replacement keyword field is not hittable")
        replacementField.tap()
        typeText("975310", into: replacementField, in: app)

        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Add Mapping"].waitForNonExistence(timeout: 5),
                      "add sheet did not dismiss after save")
        XCTAssertTrue(app.staticTexts["cardMappings.badge.246813"].waitForExistence(timeout: 5),
                      "first keyword is missing")
        XCTAssertTrue(app.staticTexts["cardMappings.badge.975310"].waitForExistence(timeout: 5),
                      "second keyword is missing")
    }
}
