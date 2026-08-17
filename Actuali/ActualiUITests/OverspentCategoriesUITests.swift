import XCTest

/// End-to-end check for the overspent badge's explanation (GH #138).
///
/// Demo data has no overspent categories, so the notice must start hidden.
/// Overspending Coffee through the real edit sheet must surface a
/// "1 Overspent Category" notice at the top of the Budget screen; tapping it
/// must list Coffee with its negative balance, and restoring the budget must
/// clear the notice again.
final class OverspentCategoriesUITests: XCTestCase {

    @MainActor
    func testNoticeExplainsOverspentCategories() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "1"]
        app.launch()

        let budgetTab = app.tabBars.buttons["tab.budget"]
        XCTAssertTrue(budgetTab.waitForExistence(timeout: 10), "Budget tab not found")

        // Demo data is within budget everywhere: no notice at launch.
        let notice = app.buttons["1 Overspent Category"]
        XCTAssertFalse(notice.exists, "overspent notice shown with nothing overspent")

        // Overspend Coffee by budgeting $1 against ~$19 already spent.
        setBudget(app, category: "Coffee", centsKeystrokes: "100")
        scrollToTop(app)
        XCTAssertTrue(notice.waitForExistence(timeout: 10),
                      "overspent notice did not appear after overspending Coffee")
        attachScreenshot(app, name: "1-overspent-notice")

        // The notice must explain itself: Coffee listed, in the red.
        notice.tap()
        let coffeeRow = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Coffee'")).firstMatch
        XCTAssertTrue(coffeeRow.waitForExistence(timeout: 5),
                      "Coffee missing from the overspent list")
        attachScreenshot(app, name: "2-overspent-list")

        // Rows drill into the month's transactions.
        coffeeRow.tap()
        XCTAssertTrue(app.navigationBars["Coffee"].waitForExistence(timeout: 5),
                      "tapping the overspent row did not open Coffee's transactions")
        attachScreenshot(app, name: "3-category-transactions")

        // Restore a healthy budget: the notice must disappear again.
        app.navigationBars.buttons.firstMatch.tap() // back to the list
        app.navigationBars.buttons.firstMatch.tap() // back to the budget
        setBudget(app, category: "Coffee", centsKeystrokes: "10000")
        scrollToTop(app)
        XCTAssertTrue(waitForNonExistence(of: notice, timeout: 10),
                      "overspent notice still shown after restoring the budget")
        attachScreenshot(app, name: "4-notice-cleared")
    }

    /// Opens the category's edit-budget sheet and types a new amount.
    /// The amount field interprets bare digits as cents ("100" → 1.00).
    @MainActor
    private func setBudget(_ app: XCUIApplication, category: String, centsKeystrokes: String) {
        let editButton = app.buttons["Edit budgeted amount for \(category)"]
        var scrollsLeft = 8
        while !editButton.isHittable && scrollsLeft > 0 {
            app.swipeUp()
            scrollsLeft -= 1
        }
        XCTAssertTrue(editButton.isHittable, "edit button for \(category) not reachable")
        editButton.tap()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "amount field not shown")
        field.tap()
        // Focus select-alls the current value asynchronously; don't rely on
        // that racing in our favor — backspace the old value away instead.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10))
        field.typeText(centsKeystrokes)

        let saveButton = app.buttons["Save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Save button not shown")
        saveButton.tap()
        // Sheet dismissal returns us to the budget list.
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "edit sheet did not dismiss")
    }

    /// The notice lives at the top of the (possibly scrolled) budget list.
    @MainActor
    private func scrollToTop(_ app: XCUIApplication) {
        for _ in 0..<8 where !app.navigationBars["Budget"].isHittable {
            app.swipeDown()
        }
        app.swipeDown()
    }

    @MainActor
    private func waitForNonExistence(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return false
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
