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
    func testDetailedGroupSwipeHidesAndShowsExpenseGroup() throws {
        try assertGroupHidesAndShowsExpenseGroup(displayStyle: "detailed")
    }

    @MainActor
    func testCompactGroupContextMenuHidesAndShowsExpenseGroup() throws {
        try assertGroupHidesAndShowsExpenseGroup(displayStyle: "compact")
    }

    @MainActor
    func testCompactGroupHeaderStaysPinnedWhileCategoriesScroll() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData", "-budgetDisplayStyle", "compact",
            "-hideZeroBudgetCategories", "NO", "-showCompactBudgetOverview", "NO",
            "-showBudgetCheckInStrip", "NO", "-initialTab", "1",
        ]
        app.launch()

        let essentials = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Essentials, ")
        ).firstMatch
        XCTAssertTrue(essentials.waitForExistence(timeout: 10))
        if essentials.label.contains("collapsed") {
            essentials.tap()
        }
        XCTAssertEqual(
            essentials.frame.minX,
            app.frame.minX,
            accuracy: 1,
            "the compact section header should not inherit List's default inset"
        )
        XCTAssertEqual(
            essentials.frame.maxX,
            app.frame.maxX,
            accuracy: 1,
            "the compact section header should remain edge-to-edge"
        )

        let category = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Details for Internet")
        ).firstMatch
        XCTAssertTrue(category.waitForExistence(timeout: 10))

        let headerY = essentials.frame.minY
        let rowY = category.frame.minY
        let start = category.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -70)))

        let headerTravel = headerY - essentials.frame.minY
        let rowTravel = rowY - category.frame.minY
        XCTAssertGreaterThan(rowTravel, 30, "the category rows should scroll")
        XCTAssertGreaterThan(
            rowTravel,
            headerTravel + 30,
            "the category row should continue under the pinned compact group header"
        )
    }

    @MainActor
    private func assertGroupHidesAndShowsExpenseGroup(displayStyle: String) throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData", "-budgetDisplayStyle", displayStyle,
            "-showHiddenCategories", "NO", "-initialTab", "1",
        ]
        app.launch()

        let essentials = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Essentials, ")
        ).firstMatch
        XCTAssertTrue(essentials.waitForExistence(timeout: 10))
        if displayStyle == "compact" {
            XCTAssertFalse(app.buttons["Options for Essentials"].exists)

            let expanded = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Essentials, expanded")
            ).firstMatch
            let collapsed = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Essentials, collapsed")
            ).firstMatch
            if collapsed.exists {
                collapsed.tap()
            }
            XCTAssertTrue(expanded.waitForExistence(timeout: 5))
            expanded.tap()
            XCTAssertTrue(collapsed.waitForExistence(timeout: 5))
            collapsed.tap()
            XCTAssertTrue(expanded.waitForExistence(timeout: 5))
        }

        setGroupHidden(true, displayStyle: displayStyle, app: app, group: essentials)
        XCTAssertTrue(essentials.waitForNonExistence(timeout: 5))

        let optionsMenu = app.buttons["Budget options"]
        optionsMenu.tap()
        let showHidden = app.buttons.matching(
            NSPredicate(
                format: "label IN %@",
                ["Show Hidden Categories", "Hidden Categories"]
            )
        ).firstMatch
        XCTAssertTrue(showHidden.waitForExistence(timeout: 5))
        showHidden.tap()
        XCTAssertTrue(essentials.waitForExistence(timeout: 5))

        setGroupHidden(false, displayStyle: displayStyle, app: app, group: essentials)

        optionsMenu.tap()
        XCTAssertTrue(showHidden.waitForExistence(timeout: 5))
        showHidden.tap()
        XCTAssertTrue(essentials.waitForExistence(timeout: 5),
                      "the group should remain visible after hidden categories are turned off")
    }

    @MainActor
    private func setGroupHidden(
        _ hidden: Bool,
        displayStyle: String,
        app: XCUIApplication,
        group: XCUIElement
    ) {
        let wasCollapsed = group.label.contains("collapsed")

        if displayStyle == "compact" {
            group.press(forDuration: 1)
        } else {
            group.swipeLeft()
        }
        XCTAssertEqual(
            group.label.contains("collapsed"),
            wasCollapsed,
            "revealing a group action must not toggle its collapse state"
        )
        let action = app.buttons[hidden ? "Hide" : "Show"].firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.tap()
    }

    @MainActor
    func testDetailedIncomeGroupHasNoHideAction() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData", "-budgetDisplayStyle", "detailed", "-initialTab", "1",
        ]
        app.launch()

        let income = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Income, ")
        ).firstMatch
        for _ in 0..<20 where !income.waitForExistence(timeout: 1) {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(income.waitForExistence(timeout: 5))

        income.swipeLeft()
        XCTAssertFalse(app.buttons["Hide"].waitForExistence(timeout: 2),
                       "the Income group must not offer a hide action")
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
    func testIncomeGroupMatchesCollapseBehaviorInCompactStyle() throws {
        try assertIncomeGroupCollapses(displayStyle: "compact")
    }

    @MainActor
    private func assertIncomeGroupCollapses(displayStyle: String) throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData", "-budgetDisplayStyle", displayStyle, "-initialTab", "1",
        ]
        app.launch()

        let firstGroup = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Essentials, '")
        ).firstMatch
        XCTAssertTrue(firstGroup.waitForExistence(timeout: 10),
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
