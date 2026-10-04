import XCTest

/// A category can be renamed from its long-press menu on the Budget tab.
final class CategoryRenameUITests: XCTestCase {
    @MainActor
    func testRenameFromLongPressMenu() {
        for style in ["clean", "compact"] {
            let app = openRename(style: style)
            replaceName("  Food  ", in: app)
            app.alerts.buttons["Save"].tap()

            XCTAssertTrue(spentButton("Food", in: app).waitForExistence(timeout: 10),
                          "the renamed category should show under its new name")
            XCTAssertFalse(spentButton("Groceries", in: app).exists)
        }
    }

    @MainActor
    func testBlankNamesDisableSave() {
        for style in ["clean", "compact"] {
            let app = openRename(style: style)
            replaceName("", in: app)
            let save = app.alerts.buttons["Save"]
            XCTAssertFalse(save.isEnabled, "an empty name must not enable Save")

            app.alerts.textFields.firstMatch.typeText("   ")
            XCTAssertFalse(save.isEnabled, "a whitespace-only name must not enable Save")
            XCTAssertTrue(app.alerts["Rename Category"].exists)

            app.alerts.buttons["Cancel"].tap()
            XCTAssertTrue(spentButton("Groceries", in: app).waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testDuplicateNameShowsError() {
        for style in ["clean", "compact"] {
            let app = openRename(style: style)
            replaceName("Rent", in: app)
            app.alerts.buttons["Save"].tap()

            XCTAssertTrue(app.alerts["Something Went Wrong"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.alerts.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "already has a category")
            ).firstMatch.exists)
            app.alerts.buttons["OK"].tap()
            XCTAssertTrue(spentButton("Groceries", in: app).exists)
        }
    }

    @MainActor
    private func openRename(style: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-budgetDisplayStyle", style, "-initialTab", "1"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Budget"].waitForExistence(timeout: 10))

        let groceries = spentButton("Groceries", in: app)
        XCTAssertTrue(groceries.waitForExistence(timeout: 10))
        scrollUntilHittable(groceries, in: app)
        groceries.press(forDuration: 1.2)

        let rename = app.buttons["categoryRename.action"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "the long-press menu should offer Rename Category")
        rename.tap()

        // iOS 18 drops SwiftUI text-field identifiers inside native alerts.
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Groceries", "the prompt starts with the current name")
        return app
    }

    @MainActor
    private func spentButton(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Transactions for \(name) in")
        ).firstMatch
    }

    @MainActor
    private func replaceName(_ name: String, in app: XCUIApplication) {
        let field = app.alerts.textFields.firstMatch
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Groceries".count))
        if !name.isEmpty {
            field.typeText(name)
        }
    }
}
