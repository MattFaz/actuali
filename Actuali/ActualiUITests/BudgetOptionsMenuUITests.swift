import XCTest

/// The Budget tab's consolidated view-options menu (GH #157): layout,
/// expand/collapse and the spent-category filter all sit behind one
/// navigation-bar button.
final class BudgetOptionsMenuUITests: XCTestCase {
    /// iOS 27 menus expose the visible title instead of custom accessibility labels.
    @MainActor private func menuOption(_ app: XCUIApplication, _ title: String, accessibilityLabel: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@", [title, accessibilityLabel])).firstMatch
    }

    @MainActor private func launchBudgetTab(_ app: XCUIApplication) {
        // Seed the persisted toggles: they survive between launches for real
        // in the simulator, so start from a known state whatever earlier runs
        // left behind.
        app.launchArguments = [
            "-loadDemoData",
            "-budgetDisplayStyle", "clean",
            "-hideZeroBudgetCategories", "NO",
            "-showCompactBudgetOverview", "YES",
            "-showCleanBudgetOverview", "YES",
            "-showBudgetedAmounts", "YES",
            "-showCompactSpentColumn", "NO",
            "-showBudgetProgressBars", "NO",
            "-showGroupTotals", "YES",
            "-showBudgetCheckInStrip", "YES",
        ]
        app.launch()
        app.tabBars.buttons["Budget"].tap()
    }

    @MainActor
    func testMenuOffersEveryBudgetViewOption() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let optionsMenu = app.buttons["Budget options"]
        XCTAssertTrue(optionsMenu.waitForExistence(timeout: 10))
        optionsMenu.tap()

        for option in ["Clean", "Compact", "Status Filters"] {
            XCTAssertTrue(app.buttons[option].waitForExistence(timeout: 5),
                          "the options menu should offer '\(option)'")
        }
        for (title, accessibilityLabel) in [
            ("Expand Groups", "Expand All Groups"),
            ("Collapse Groups", "Collapse All Groups"),
            ("Hide Spent", "Hide Spent Categories"),
            ("Hidden Categories", "Show Hidden Categories"),
            ("Show Budgeted", "Budgeted Amounts"),
        ] {
            XCTAssertTrue(menuOption(app, title, accessibilityLabel: accessibilityLabel).waitForExistence(timeout: 5),
                          "the options menu should offer '\(title)'")
        }
        XCTAssertFalse(app.buttons["Detailed"].exists)
        XCTAssertTrue(app.buttons["Show Overview"].exists, "Show Overview applies to both styles")
        XCTAssertFalse(menuOption(app, "Show Spent", accessibilityLabel: "Show Spent Column").exists,
                       "Clean should not offer the Compact-only 'Show Spent Column' control")
        XCTAssertFalse(app.buttons["Group Totals"].exists,
                       "Group Totals remains exclusive to Compact")
    }

    @MainActor
    func testCompactControlsAreConditionalAndCorrectlySeeded() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let optionsMenu = app.buttons["Budget options"]
        XCTAssertTrue(optionsMenu.waitForExistence(timeout: 10))
        optionsMenu.tap()
        app.buttons["Compact"].tap()

        optionsMenu.tap()
        let overview = app.buttons["Show Overview"]
        let spent = menuOption(app, "Show Spent", accessibilityLabel: "Show Spent Column")
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
        XCTAssertTrue(spent.exists)
        XCTAssertTrue(overview.isSelected, "Show Overview defaults on")
        XCTAssertTrue(app.buttons["Group Totals"].exists)
        XCTAssertFalse(spent.isSelected,
                       "the launch argument seeds Show Spent Column off")
        XCTAssertFalse(app.buttons["Progress Indicators"].exists,
                       "Compact uses the shared Budget Progress Bars setting")

        app.buttons["Clean"].tap()
        optionsMenu.tap()
        XCTAssertTrue(app.buttons["Compact"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Group Totals"].exists)
        XCTAssertTrue(app.buttons["Show Overview"].exists)
        XCTAssertFalse(spent.exists)
        XCTAssertFalse(app.buttons["Progress Indicators"].exists)
    }

    @MainActor
    func testCleanOverviewTogglesFromTheMenu() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let topBox = app.otherElements["budget.topBox"]
        XCTAssertTrue(topBox.waitForExistence(timeout: 10), "the clean summary shows by default")

        app.buttons["Budget options"].tap()
        let overview = app.buttons["Show Overview"]
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
        overview.tap()
        XCTAssertTrue(topBox.waitForNonExistence(timeout: 5), "turning Show Overview off hides the summary")
        XCTAssertTrue(app.buttons["budget.readyToBudget"].waitForExistence(timeout: 5),
                      "with the overview hidden, a Ready to Budget row keeps the amount in view")

        // Remove the argument-domain override to exercise the real saved preference.
        app.terminate()
        app.launchArguments = [
            "-loadDemoData", "-budgetDisplayStyle", "clean",
            "-showCompactBudgetOverview", "YES", "-initialTab", "1",
        ]
        app.launch()
        let readyToBudget = app.buttons["budget.readyToBudget"]
        XCTAssertTrue(readyToBudget.waitForExistence(timeout: 10), "the hidden overview survives relaunch")
        XCTAssertFalse(topBox.exists)
        readyToBudget.tap()
        let closeSummary = app.buttons["Close Budget Summary"]
        XCTAssertTrue(closeSummary.waitForExistence(timeout: 5), "the row opens the budget summary")
        closeSummary.tap()

        app.buttons["Budget options"].tap()
        app.buttons["Compact"].tap()
        app.buttons["Budget options"].tap()
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
        XCTAssertTrue(overview.isSelected, "hiding Clean does not hide the Compact overview")
        app.buttons["Clean"].tap()

        app.buttons["Budget options"].tap()
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
        XCTAssertFalse(overview.isSelected, "returning to Clean keeps its independent preference")
        overview.tap()
        XCTAssertTrue(topBox.waitForExistence(timeout: 5), "turning it back on restores the summary")
        XCTAssertFalse(app.buttons["budget.readyToBudget"].exists, "the row is only shown while the overview is hidden")
    }

    @MainActor
    func testHiddenOverviewShowsOverbudgetedAmount() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let editGroceries = app.buttons["Edit budgeted amount for Groceries"].firstMatch
        XCTAssertTrue(editGroceries.waitForExistence(timeout: 10))
        editGroceries.tap()
        let amount = app.textFields.firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + "10000000")
        app.buttons["Save"].tap()
        XCTAssertTrue(amount.waitForNonExistence(timeout: 5))

        app.buttons["Budget options"].tap()
        app.buttons["Show Overview"].tap()
        let row = app.buttons["budget.readyToBudget"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.hasPrefix("Overbudgeted,"), "negative funds must not read Ready to Budget")

        app.buttons["Budget options"].tap()
        app.buttons["Show Overview"].tap()
    }

    @MainActor
    func testHiddenTrackingOverviewHasNoReadyToBudgetRow() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData", "-loadTrackingDemoData", "-budgetDisplayStyle", "clean",
            "-showCleanBudgetOverview", "NO", "-initialTab", "1",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["Details for Groceries"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["budget.topBox"].exists)
        XCTAssertFalse(app.buttons["budget.readyToBudget"].exists,
                       "tracking budgets have no amount left to allocate")
    }

    /// The strip costs a row of vertical space on a phone, so it's optional.
    /// Flip the launch-seeded state and put it back so the persisted setting
    /// still cannot leak into another test.
    @MainActor
    func testStatusFilterStripTogglesFromTheMenu() {
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
    func testHideSpentCategoriesTogglesFromTheMenu() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let optionsMenu = app.buttons["Budget options"]
        XCTAssertTrue(optionsMenu.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Details for Groceries"].firstMatch
            .waitForExistence(timeout: 10),
            "demo data should show the Essentials categories")

        optionsMenu.tap()
        let hideSpent = menuOption(app, "Hide Spent", accessibilityLabel: "Hide Spent Categories")
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
