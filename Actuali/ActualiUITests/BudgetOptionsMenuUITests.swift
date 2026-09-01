import XCTest

/// The Budget tab's consolidated view-options menu (GH #157): layout,
/// expand/collapse and the spent-category filter all sit behind one
/// navigation-bar button.
final class BudgetOptionsMenuUITests: XCTestCase {

    @MainActor private func launchBudgetTab(_ app: XCUIApplication) {
        // Seed the persisted toggles: they survive between launches for real
        // in the simulator, so start from a known state whatever earlier runs
        // left behind.
        app.launchArguments = [
            "-loadDemoData",
            "-budgetDisplayStyle", "clean",
            "-hideZeroBudgetCategories", "NO",
            "-showCompactBudgetOverview", "YES",
            "-showCompactSpentColumn", "NO",
            "-showBudgetProgressBars", "NO",
            "-showGroupTotals", "YES",
            "-showBudgetCheckInStrip", "YES",
        ]
        app.launch()
        app.tabBars.buttons["Budget"].tap()
    }

    @MainActor
    func testMenuOffersEveryBudgetViewOption() throws {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let optionsMenu = app.buttons["Budget options"]
        XCTAssertTrue(optionsMenu.waitForExistence(timeout: 10))
        optionsMenu.tap()

        for option in ["Clean", "Detailed", "Compact", "Expand All Groups",
                       "Collapse All Groups", "Status Filters",
                       "Hide Spent Categories", "Show Hidden Categories"] {
            XCTAssertTrue(app.buttons[option].waitForExistence(timeout: 5),
                          "the options menu should offer '\(option)'")
        }
        for compactOption in ["Show Overview", "Show Spent Column"] {
            XCTAssertFalse(app.buttons[compactOption].exists,
                           "Clean should not offer the Compact-only '\(compactOption)' control")
        }
        XCTAssertFalse(app.buttons["Group Totals"].exists,
                       "Group Totals remains exclusive to Detailed")
    }

    @MainActor
    func testCompactControlsAreConditionalAndCorrectlyDefaulted() throws {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let optionsMenu = app.buttons["Budget options"]
        XCTAssertTrue(optionsMenu.waitForExistence(timeout: 10))
        optionsMenu.tap()
        app.buttons["Compact"].tap()

        optionsMenu.tap()
        let overview = app.buttons["Show Overview"]
        let spent = app.buttons["Show Spent Column"]
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
        XCTAssertTrue(spent.exists)
        XCTAssertTrue(overview.isSelected, "Show Overview defaults on")
        XCTAssertTrue(app.buttons["Group Totals"].exists)
        XCTAssertFalse(spent.isSelected, "Show Spent Column defaults off")
        XCTAssertFalse(app.buttons["Progress Indicators"].exists,
                       "Compact uses the shared Budget Progress Bars setting")

        app.buttons["Detailed"].tap()
        optionsMenu.tap()
        XCTAssertTrue(app.buttons["Group Totals"].waitForExistence(timeout: 5),
                      "Detailed keeps its existing Group Totals control")
        XCTAssertFalse(app.buttons["Show Overview"].exists)
        XCTAssertFalse(app.buttons["Show Spent Column"].exists)
        XCTAssertFalse(app.buttons["Progress Indicators"].exists)
    }

    /// The strip costs a row of vertical space on a phone, so it's optional.
    /// Flip the launch-seeded state and put it back so the persisted setting
    /// still cannot leak into another test.
    @MainActor
    func testStatusFilterStripTogglesFromTheMenu() throws {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let optionsMenu = app.buttons["Budget options"]
        XCTAssertTrue(optionsMenu.waitForExistence(timeout: 10))
        let statusFilters = app.buttons["Status Filters"]
        let allChip = app.buttons["budgetFilter-all"]

        optionsMenu.tap()
        XCTAssertTrue(statusFilters.waitForExistence(timeout: 5))
        let startedShown = statusFilters.isSelected
        XCTAssertEqual(allChip.exists, startedShown,
                       "the strip's visibility should match the menu toggle")

        statusFilters.tap()
        if startedShown {
            XCTAssertTrue(allChip.waitForNonExistence(timeout: 5),
                          "turning the toggle off should hide the strip")
        } else {
            XCTAssertTrue(allChip.waitForExistence(timeout: 5),
                          "turning the toggle on should show the strip")
        }

        // Restore, so the live-persisted setting doesn't leak into other tests.
        optionsMenu.tap()
        XCTAssertTrue(statusFilters.waitForExistence(timeout: 5))
        statusFilters.tap()
        XCTAssertEqual(allChip.waitForExistence(timeout: 5), startedShown,
                       "toggling back should restore the original state")
    }

    @MainActor
    func testHideSpentCategoriesTogglesFromTheMenu() throws {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let optionsMenu = app.buttons["Budget options"]
        XCTAssertTrue(optionsMenu.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Details for Groceries"].firstMatch
            .waitForExistence(timeout: 10),
                      "demo data should show the Essentials categories")

        optionsMenu.tap()
        let hideSpent = app.buttons["Hide Spent Categories"]
        XCTAssertTrue(hideSpent.waitForExistence(timeout: 5))
        XCTAssertFalse(hideSpent.isSelected, "the filter starts off")
        hideSpent.tap()

        // Reopen: a checked menu toggle reports as selected.
        optionsMenu.tap()
        XCTAssertTrue(hideSpent.waitForExistence(timeout: 5))
        XCTAssertTrue(hideSpent.isSelected, "tapping the menu item turns the filter on")

        // Restore, so the live-persisted setting doesn't leak into other tests.
        hideSpent.tap()
        optionsMenu.tap()
        XCTAssertTrue(hideSpent.waitForExistence(timeout: 5))
        XCTAssertFalse(hideSpent.isSelected, "tapping again turns the filter back off")
    }
}
