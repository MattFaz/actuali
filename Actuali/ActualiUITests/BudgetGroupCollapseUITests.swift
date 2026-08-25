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

        let groceries = app.buttons["Details for Groceries"].firstMatch
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

    @MainActor
    func testToolbarMenuCollapsesAndExpandsAllGroups() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()

        app.tabBars.buttons["Budget"].tap()

        let groceries = app.buttons["Details for Groceries"].firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 10),
                      "demo data should show the Essentials categories")

        let menuButton = app.buttons["Budget options"]
        XCTAssertTrue(menuButton.waitForExistence(timeout: 10),
                      "the budget toolbar should offer the options menu")
        menuButton.tap()

        let collapseAll = app.buttons["Collapse All Groups"]
        XCTAssertTrue(collapseAll.waitForExistence(timeout: 10))
        collapseAll.tap()

        // Every group collapses, not just the first one.
        XCTAssertTrue(app.buttons["Essentials, collapsed"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Lifestyle, collapsed"].waitForExistence(timeout: 10),
                      "collapse all should also collapse the other groups")
        XCTAssertFalse(groceries.exists,
                       "collapse all should hide the category rows")

        menuButton.tap()

        let expandAll = app.buttons["Expand All Groups"]
        XCTAssertTrue(expandAll.waitForExistence(timeout: 10))
        expandAll.tap()

        XCTAssertTrue(app.buttons["Essentials, expanded"].waitForExistence(timeout: 10))
        // Transport sits right below Essentials, so it stays on screen; the
        // lower groups scroll out of the lazy list's accessibility tree once
        // everything is expanded, so they can't be asserted here.
        XCTAssertTrue(app.buttons["Transport, expanded"].waitForExistence(timeout: 10),
                      "expand all should also expand the other groups")
        XCTAssertTrue(groceries.waitForExistence(timeout: 10),
                      "expand all should restore the category rows")
    }

    @MainActor
    func testIncomeGroupMatchesCollapseBehaviorInCleanStyle() throws {
        try assertIncomeGroupCollapses(displayStyle: "clean")
    }

    @MainActor
    func testIncomeGroupMatchesCollapseBehaviorInDetailedStyle() throws {
        try assertIncomeGroupCollapses(displayStyle: "detailed")
    }

    @MainActor
    private func assertIncomeGroupCollapses(displayStyle: String) throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData", "-budgetDisplayStyle", displayStyle, "-initialTab", "1",
        ]
        app.launch()

        let groceries = app.buttons["Details for Groceries"].firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 10),
                      "demo data should load before scrolling to the income group")

        let incomeGroupName = "Income"
        let anyHeader = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "\(incomeGroupName), ")
        ).firstMatch
        let expandedHeader = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "\(incomeGroupName), expanded")
        ).firstMatch
        let collapsedHeader = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "\(incomeGroupName), collapsed")
        ).firstMatch
        let salary = app.buttons["All transactions for Salary"]

        var scrollsLeft = 20
        while !anyHeader.waitForExistence(timeout: 2) && scrollsLeft > 0 {
            app.swipeUp(velocity: .slow)
            scrollsLeft -= 1
        }
        XCTAssertTrue(anyHeader.waitForExistence(timeout: 10),
                      "the income group header should be reachable")
        if collapsedHeader.isHittable {
            collapsedHeader.tap()
        }

        XCTAssertTrue(expandedHeader.waitForExistence(timeout: 10))
        XCTAssertTrue(salary.waitForExistence(timeout: 10))
        expandedHeader.tap()

        XCTAssertTrue(collapsedHeader.waitForExistence(timeout: 10))
        XCTAssertFalse(salary.exists, "collapsing Income should hide its categories")
    }
}
