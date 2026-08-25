import XCTest

/// End-to-end check for the overspent workflow (GH #138), now that the
/// check-in card and its dedicated list are replaced by the status strip.
///
/// Demo data has no overspent categories, so the Overspent filter must start
/// empty. Overspending Coffee through the real edit sheet must make the filter
/// isolate Coffee in the budget table; covering it from Coffee's own balance
/// must empty the filter again.
final class OverspentCategoriesUITests: XCTestCase {

    @MainActor
    func testOverspentFilterIsolatesAndResolvesOverspentCategories() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "1"]
        app.launch()

        let budgetTab = app.tabBars.buttons["Budget"]
        XCTAssertTrue(budgetTab.waitForExistence(timeout: 10), "Budget tab not found")
        XCTAssertTrue(app.buttons["Details for Groceries"].firstMatch.waitForExistence(timeout: 10),
                      "budget table did not load")

        // Demo data is within budget everywhere: nothing to show.
        tapBudgetFilter(app, "overspent")
        let emptyState = app.staticTexts["No Matching Categories"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 10),
                      "overspent filter matched something with nothing overspent")
        attachScreenshot(app, name: "1-overspent-filter-empty")

        // Overspend Coffee by budgeting $1 against ~$19 already spent.
        tapBudgetFilter(app, "all")
        setBudget(app, category: "Coffee", centsKeystrokes: "100")
        scrollToTop(app)
        tapBudgetFilter(app, "overspent")

        // The filter must explain itself: Coffee in the table, nothing else.
        let coffeeRow = app.buttons["Details for Coffee"].firstMatch
        XCTAssertTrue(coffeeRow.waitForExistence(timeout: 10),
                      "Coffee missing from the overspent filter")
        XCTAssertFalse(app.buttons["Details for Groceries"].exists,
                       "the overspent filter left a healthy category in the table")
        attachScreenshot(app, name: "2-overspent-filtered")

        // Rows still drill into the month's transactions.
        coffeeRow.tap()
        XCTAssertTrue(app.navigationBars["Edit Category"].waitForExistence(timeout: 5),
                      "tapping the category name did not open the compact editor")
        app.buttons["Cancel"].tap()

        // Resolving is a visible action on the row's own balance.
        let cover = app.buttons["Cover overspending for Coffee"]
        XCTAssertTrue(cover.waitForExistence(timeout: 5),
                      "an overspent balance should offer a visible resolution action")
        cover.tap()
        XCTAssertTrue(app.navigationBars["Cover Overspending"].waitForExistence(timeout: 5),
                      "the balance did not open the cover flow")
        app.buttons["Move"].tap()

        XCTAssertTrue(emptyState.waitForExistence(timeout: 10),
                      "Coffee still matched the overspent filter after covering it")
        attachScreenshot(app, name: "3-overspent-filter-cleared")
    }

    /// The status strip is pinned above the (possibly scrolled) budget list.
    @MainActor
    private func scrollToTop(_ app: XCUIApplication) {
        for _ in 0..<8 where !app.navigationBars["Budget"].isHittable {
            app.swipeDown()
        }
        app.swipeDown()
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
