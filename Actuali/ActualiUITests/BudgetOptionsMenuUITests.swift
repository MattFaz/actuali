import XCTest

/// The ellipsis menu groups style, budget display and month actions into nested menus.
final class BudgetOptionsMenuUITests: XCTestCase {
    @MainActor private func menuOption(
        _ app: XCUIApplication,
        _ title: String,
        accessibilityLabel: String
    ) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@", [title, accessibilityLabel])).firstMatch
    }

    @MainActor private func launchBudgetTab(_ app: XCUIApplication) {
        app.launchArguments = [
            "-loadDemoData",
            "-initialTab", "1",
            "-budgetDisplayStyle", "clean",
            "-hideZeroBudgetCategories", "NO",
            "-showCompactBudgetOverview", "YES",
            "-showCleanBudgetOverview", "YES",
            "-showBudgetedAmounts", "YES",
            "-showCompactSpentColumn", "NO",
            "-showBudgetProgressBars", "NO",
            "-showGroupTotals", "YES",
            "-showBudgetCheckInStrip", "YES",
            "-showHiddenCategories", "NO",
        ]
        app.launch()
        app.tabBars.buttons["Budget"].tap()
    }

    @MainActor private func openBudgetViewMenu(_ app: XCUIApplication) {
        app.buttons["Budget options"].tap()
        app.buttons["Budget View"].tap()
    }

    @MainActor private func openStyleMenu(_ app: XCUIApplication) {
        app.buttons["Budget options"].tap()
        app.buttons["Style"].tap()
    }

    @MainActor
    func testEllipsisOffersThreeSubmenusAndNoteAction() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let optionsMenu = app.buttons["Budget options"]
        XCTAssertTrue(optionsMenu.waitForExistence(timeout: 10))
        optionsMenu.tap()
        for submenu in ["Style", "Budget View", "Actions"] {
            XCTAssertTrue(app.buttons[submenu].waitForExistence(timeout: 5),
                          "the ellipsis menu should offer '\(submenu)'")
        }
        XCTAssertFalse(app.buttons["Clean"].exists, "style options should be inside Style")
        XCTAssertFalse(app.buttons["Show Overview"].exists, "display options should be inside Budget View")
        XCTAssertFalse(app.buttons["Hidden Categories"].exists,
                       "Hidden Categories belongs to the Actuali logo menu")
        XCTAssertFalse(app.buttons["New Category"].exists)
        XCTAssertFalse(app.buttons["Reorder Items"].exists)
        XCTAssertFalse(app.buttons["Notes"].exists,
                       "month notes should not have a separate submenu")
        XCTAssertTrue(app.buttons["budget.monthNote"].waitForExistence(timeout: 5),
                      "Add Note or Edit Note should be directly in the ellipsis menu")
    }

    @MainActor
    func testBudgetViewSubmenuOffersEveryDisplayOption() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        app.buttons["Budget options"].tap()
        app.buttons["Budget View"].tap()

        let overview = app.buttons["Show Overview"]
        let budgeted = menuOption(app, "Show Budgeted", accessibilityLabel: "Budgeted Amounts")
        let spent = menuOption(app, "Show Spent", accessibilityLabel: "Show Spent Column")
        let totals = app.buttons["Group Totals"]
        let statusFilters = app.buttons["Status Filters"]
        let hideSpent = menuOption(app, "Hide Spent", accessibilityLabel: "Hide Spent Categories")
        for (name, element) in [
            ("Show Overview", overview),
            ("Show Budgeted", budgeted),
            ("Show Spent", spent),
            ("Group Totals", totals),
            ("Status Filters", statusFilters),
            ("Hide Spent", hideSpent),
        ] {
            XCTAssertTrue(element.waitForExistence(timeout: 5),
                          "Budget View should contain '\(name)'")
        }
        XCTAssertTrue(overview.isSelected, "Show Overview defaults on")
        XCTAssertFalse(spent.isEnabled, "Show Spent applies to Compact style")
        XCTAssertFalse(totals.isEnabled, "Group Totals applies to Compact style")
        XCTAssertFalse(app.buttons["Expand Groups"].exists,
                       "global group expansion belongs in the Actuali menu")
        XCTAssertFalse(app.buttons["Collapse Groups"].exists,
                       "global group collapse belongs in the Actuali menu")
    }

    @MainActor
    func testStyleSubmenuChangesStyleAndKeepsCompactSettingsAvailable() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        openStyleMenu(app)
        XCTAssertTrue(app.buttons["Clean"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Compact"].exists)
        app.buttons["Compact"].tap()

        openBudgetViewMenu(app)
        let overview = app.buttons["Show Overview"]
        let spent = menuOption(app, "Show Spent", accessibilityLabel: "Show Spent Column")
        let totals = app.buttons["Group Totals"]
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
        XCTAssertTrue(spent.isEnabled)
        XCTAssertTrue(totals.isEnabled)
        XCTAssertFalse(spent.isSelected, "launch argument seeds Show Spent off")
        XCTAssertTrue(totals.isSelected, "launch argument seeds Group Totals on")
        XCTAssertFalse(app.buttons["Progress Indicators"].exists)

        openStyleMenu(app)
        app.buttons["Clean"].tap()
        openBudgetViewMenu(app)
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
        XCTAssertTrue(spent.exists)
        XCTAssertFalse(spent.isEnabled)
        XCTAssertTrue(totals.exists)
        XCTAssertFalse(totals.isEnabled)
        XCTAssertFalse(app.buttons["Progress Indicators"].exists)
    }

    @MainActor
    func testCleanOverviewTogglesFromBudgetViewSubmenu() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let topBox = app.otherElements["budget.topBox"]
        XCTAssertTrue(topBox.waitForExistence(timeout: 10), "the clean summary shows by default")

        openBudgetViewMenu(app)
        let overview = app.buttons["Show Overview"]
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
        overview.tap()
        XCTAssertTrue(topBox.waitForNonExistence(timeout: 5), "turning Show Overview off hides the summary")
        XCTAssertTrue(app.buttons["budget.readyToBudget"].waitForExistence(timeout: 5),
                      "with the overview hidden, a Ready to Budget row keeps the amount in view")

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

        openStyleMenu(app)
        app.buttons["Compact"].tap()
        openBudgetViewMenu(app)
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
        XCTAssertTrue(overview.isSelected, "Show Overview defaults on for Compact")
        openStyleMenu(app)
        app.buttons["Clean"].tap()

        openBudgetViewMenu(app)
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
        XCTAssertFalse(overview.isSelected, "Clean's hidden overview preference survives style changes")
        overview.tap()
        XCTAssertTrue(topBox.waitForExistence(timeout: 5), "turning it back on restores the summary")
        XCTAssertFalse(app.buttons["budget.readyToBudget"].exists)
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

        openBudgetViewMenu(app)
        app.buttons["Show Overview"].tap()
        let row = app.buttons["budget.readyToBudget"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.hasPrefix("Overbudgeted,"), "negative funds must not read Ready to Budget")

        openBudgetViewMenu(app)
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

    @MainActor
    func testStatusFilterStripTogglesFromBudgetViewSubmenu() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let allChip = app.buttons["budgetFilter-all"]
        openBudgetViewMenu(app)
        let statusFilters = app.buttons["Status Filters"]
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

        openBudgetViewMenu(app)
        let toggled = app.buttons["Status Filters"]
        XCTAssertTrue(toggled.waitForExistence(timeout: 5))
        toggled.tap()
        XCTAssertEqual(allChip.waitForExistence(timeout: 5), startedShown,
                       "toggling back should restore the original state")
    }

    @MainActor
    func testHideSpentCategoriesTogglesFromBudgetViewSubmenu() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        XCTAssertTrue(app.buttons["Details for Groceries"].firstMatch
            .waitForExistence(timeout: 10),
            "demo data should show the Essentials categories")

        openBudgetViewMenu(app)
        let hideSpent = menuOption(app, "Hide Spent", accessibilityLabel: "Hide Spent Categories")
        XCTAssertTrue(hideSpent.waitForExistence(timeout: 5))
        XCTAssertFalse(hideSpent.isSelected, "the filter starts off")
        hideSpent.tap()

        openBudgetViewMenu(app)
        let enabled = menuOption(app, "Hide Spent", accessibilityLabel: "Hide Spent Categories")
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        XCTAssertTrue(enabled.isSelected, "tapping the menu item turns the filter on")

        enabled.tap()
        openBudgetViewMenu(app)
        XCTAssertFalse(menuOption(
            app, "Hide Spent", accessibilityLabel: "Hide Spent Categories"
        ).isSelected, "tapping again turns the filter back off")
    }

    @MainActor
    func testMonthPickerShowsYearAndTwelveMonthGrid() throws {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let monthPicker = app.buttons["budget.monthStepper"]
        XCTAssertTrue(monthPicker.waitForExistence(timeout: 10))
        monthPicker.tap()

        let year = app.staticTexts["budget.monthPicker.year"]
        let previousYear = app.buttons["budget.monthPicker.previousYear"]
        let nextYear = app.buttons["budget.monthPicker.nextYear"]
        let months = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "budget.monthPicker.month.")
        )

        XCTAssertTrue(year.waitForExistence(timeout: 5))
        XCTAssertTrue(previousYear.exists)
        XCTAssertTrue(nextYear.exists)
        XCTAssertEqual(months.count, 12, "the picker should show all twelve months")
        XCTAssertFalse(app.buttons["budget.monthNote"].exists,
                       "month notes should no longer appear in the month picker")

        let startingYear = try XCTUnwrap(Int(year.label))
        nextYear.tap()
        XCTAssertEqual(Int(year.label), startingYear + 1)
        previousYear.tap()
        XCTAssertEqual(Int(year.label), startingYear)

        let january = app.buttons["budget.monthPicker.month.\(startingYear)-01"]
        XCTAssertTrue(january.waitForExistence(timeout: 5))
        let januaryTitle = january.label
        january.tap()

        XCTAssertTrue(app.buttons["budget.monthStepper"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["budget.monthStepper"].label, januaryTitle)
        XCTAssertFalse(year.exists, "selecting a month should dismiss the picker")

        let optionsMenu = app.buttons["Budget options"]
        XCTAssertTrue(optionsMenu.waitForExistence(timeout: 5))
        optionsMenu.tap()
        XCTAssertFalse(app.buttons["Notes"].exists)
        XCTAssertTrue(app.buttons["budget.monthNote"].waitForExistence(timeout: 5),
                      "month notes should be a direct action in the ellipsis menu")
    }
}
