import XCTest

/// PWA-style budget table (actios-yif1): group rows collapse and re-expand
/// their categories, and the collapsed state survives leaving the tab.
final class BudgetGroupCollapseUITests: XCTestCase {

    @MainActor
    func testGroupRowCollapsesAndExpandsCategories() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()

        app.tabBars.buttons["tab.budget"].tap()

        let groceries = app.buttons["budget.transactions.Groceries"].firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 10),
                      "demo data should show the Essentials categories")

        let expandedHeader = app.buttons["budget.group.essentials"]
        XCTAssertTrue(expandedHeader.waitForExistence(timeout: 10))
        expandedHeader.tap()

        // Collapsing hides the group's category rows but keeps the totals row.
        let collapsedHeader = app.buttons["budget.group.essentials"]
        XCTAssertTrue(collapsedHeader.waitForExistence(timeout: 10))
        XCTAssertTrue(groceries.waitForNonExistence(timeout: 5),
                  "collapsing Essentials should hide its categories")

        collapsedHeader.tap()
        XCTAssertTrue(groceries.waitForExistence(timeout: 10),
                      "expanding Essentials should restore its categories")
    }

    @MainActor
    func testToolbarMenuCollapsesAndExpandsAllGroups() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()

        app.tabBars.buttons["tab.budget"].tap()

        let groceries = app.buttons["budget.transactions.Groceries"].firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 10),
                      "demo data should show the Essentials categories")

        let menuButton = app.buttons["budget.options"]
        XCTAssertTrue(menuButton.waitForExistence(timeout: 10),
                      "the budget toolbar should offer the options menu")
        menuButton.tap()

        let collapseAll = app.buttons["budget.collapseAllGroups"]
        XCTAssertTrue(collapseAll.waitForExistence(timeout: 10))
        collapseAll.tap()

        // Every group collapses, not just the first one.
        XCTAssertTrue(app.buttons["budget.group.essentials"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["budget.group.lifestyle"].waitForExistence(timeout: 10),
                      "collapse all should also collapse the other groups")
        XCTAssertTrue(groceries.waitForNonExistence(timeout: 5),
                  "collapse all should hide the category rows")

        menuButton.tap()

        let expandAll = app.buttons["budget.expandAllGroups"]
        XCTAssertTrue(expandAll.waitForExistence(timeout: 10))
        expandAll.tap()

        XCTAssertTrue(app.buttons["budget.group.essentials"].waitForExistence(timeout: 10))
        // Transport sits right below Essentials, so it stays on screen; the
        // lower groups scroll out of the lazy list's accessibility tree once
        // everything is expanded, so they can't be asserted here.
        XCTAssertTrue(app.buttons["budget.group.transport"].waitForExistence(timeout: 10),
                      "expand all should also expand the other groups")
        XCTAssertTrue(groceries.waitForExistence(timeout: 10),
                      "expand all should restore the category rows")
    }
}
