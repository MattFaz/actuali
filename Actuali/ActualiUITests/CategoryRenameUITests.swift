import XCTest

/// A category can be renamed from its long-press menu on the Budget tab.
final class CategoryRenameUITests: XCTestCase {
    @MainActor
    func testRenameFromLongPressMenu() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-budgetDisplayStyle", "clean", "-initialTab", "1"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Budget"].waitForExistence(timeout: 10))

        func spentButton(_ name: String) -> XCUIElement {
            app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Transactions for \(name) in")
            ).firstMatch
        }

        let groceries = spentButton("Groceries")
        XCTAssertTrue(groceries.waitForExistence(timeout: 10))
        scrollUntilHittable(groceries, in: app)
        groceries.press(forDuration: 1.2)

        let rename = app.buttons["Rename Category"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "the long-press menu should offer Rename Category")
        rename.tap()

        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Groceries", "the prompt starts with the current name")
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Groceries".count))
        field.typeText("Food")
        app.alerts.buttons["Save"].tap()

        XCTAssertTrue(spentButton("Food").waitForExistence(timeout: 10),
                      "the renamed category should show under its new name")
        XCTAssertFalse(spentButton("Groceries").exists)
    }
}
