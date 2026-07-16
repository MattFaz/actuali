import XCTest

/// PWA-style budget table (actios-yif1): group rows collapse and re-expand
/// their categories, and the collapsed state survives leaving the tab.
final class BudgetGroupCollapseUITests: XCTestCase {

    @MainActor
    func testGroupRowCollapsesAndExpandsCategories() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()

        app.tabBars.buttons["Budget"].tap()

        let groceries = app.buttons["All transactions for Groceries"].firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 10),
                      "demo data should show the Essentials categories")

        let expandedHeader = app.buttons["Essentials, expanded"]
        XCTAssertTrue(expandedHeader.waitForExistence(timeout: 10))
        expandedHeader.tap()

        // Collapsing hides the group's category rows but keeps the totals row.
        let collapsedHeader = app.buttons["Essentials, collapsed"]
        XCTAssertTrue(collapsedHeader.waitForExistence(timeout: 10))
        XCTAssertFalse(groceries.exists,
                       "collapsing Essentials should hide its categories")

        collapsedHeader.tap()
        XCTAssertTrue(groceries.waitForExistence(timeout: 10),
                      "expanding Essentials should restore its categories")
    }
}
