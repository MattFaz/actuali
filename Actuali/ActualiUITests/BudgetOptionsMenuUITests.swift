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
            "-showTransactionImpactCue", "YES",
            "-showCategoryStatusDots", "YES",
            "-showInverseBudgetProgressBars", "NO",
            "-showOverspentBadge", "YES",
            "-hideIncomeGroup", "NO",
            "-showGroupTotals", "YES",
            "-showBudgetCheckInStrip", "YES",
            "-showHiddenCategories", "NO",
        ]
        app.launch()
        app.tabBars.buttons["Budget"].tap()
    }

    @MainActor private func firstBudgetProgressBar(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label MATCHES[c] '.*spent [0-9]+ percent.*'")
        ).firstMatch
    }

    @MainActor private func openBudgetViewMenu(_ app: XCUIApplication) {
        app.buttons["Budget options"].tap()
        app.buttons["Budget View"].tap()
    }

    /// Taps outside an open menu. Needed only after reading items without
    /// tapping one, since tapping an item already closes the menu.
    @MainActor private func dismissMenu(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
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
        let statusDots = app.buttons["budgetOptions.showCategoryStatusDots"]
        let progressBars = app.buttons["budgetOptions.showBudgetProgressBars"]
        let inverseProgressBars = app.buttons["budgetOptions.showInverseBudgetProgressBars"]
        let overspentBadge = app.buttons["budgetOptions.showOverspentBadge"]
        let hideIncomeGroup = app.buttons["budgetOptions.hideIncomeGroup"]
        let balanceImpact = app.buttons["budgetOptions.showBalanceImpact"]
        let colorPicker = app.buttons["budgetOptions.colorPicker"]
        for (name, element) in [
            ("Show Overview", overview),
            ("Show Budgeted", budgeted),
            ("Show Spent", spent),
            ("Group Totals", totals),
            ("Status Filters", statusFilters),
            ("Hide Spent", hideSpent),
            ("Category Status Dots", statusDots),
            ("Budget Progress Bars", progressBars),
            ("Inverse Progress Bars", inverseProgressBars),
            ("Overspent Badge", overspentBadge),
            ("Hide Income Group", hideIncomeGroup),
            ("Show Balance Impact", balanceImpact),
            ("Color picker", colorPicker),
        ] {
            XCTAssertTrue(element.waitForExistence(timeout: 5),
                          "Budget View should contain '\(name)'")
        }
        XCTAssertTrue(overview.isSelected, "Show Overview defaults on")
        XCTAssertTrue(statusDots.isSelected, "Category Status Dots default on")
        XCTAssertFalse(progressBars.isSelected, "Budget Progress Bars are seeded off")
        XCTAssertFalse(inverseProgressBars.isEnabled, "Inverse bars require Budget Progress Bars")
        XCTAssertTrue(overspentBadge.isSelected, "Overspent Badge defaults on")
        XCTAssertFalse(hideIncomeGroup.isSelected, "Hide Income Group defaults off")
        XCTAssertTrue(balanceImpact.isSelected, "Show Balance Impact defaults on")
        XCTAssertFalse(spent.isEnabled, "Show Spent applies to Compact style")
        XCTAssertFalse(totals.isEnabled, "Group Totals applies to Compact style")
        XCTAssertFalse(app.buttons["Expand Groups"].exists,
                       "global group expansion belongs in the Actuali menu")
        XCTAssertFalse(app.buttons["Collapse Groups"].exists,
                       "global group collapse belongs in the Actuali menu")
    }

    @MainActor
    func testCategoryStatusDotsToggleControlsBudgetRows() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let statusDot = app.descendants(matching: .any)["categoryStatusDot"].firstMatch
        XCTAssertTrue(statusDot.waitForExistence(timeout: 10),
                      "The demo budget should start with visible category status dots")

        openBudgetViewMenu(app)
        let toggle = app.buttons["budgetOptions.showCategoryStatusDots"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(toggle.isSelected, "Category Status Dots starts enabled")
        toggle.tap()

        XCTAssertTrue(statusDot.waitForNonExistence(timeout: 5),
                      "Turning Category Status Dots off should remove them from category rows")

        openBudgetViewMenu(app)
        let restore = app.buttons["budgetOptions.showCategoryStatusDots"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        XCTAssertFalse(restore.isSelected, "Category Status Dots should now be disabled")
        restore.tap()

        XCTAssertTrue(statusDot.waitForExistence(timeout: 5),
                      "Turning Category Status Dots back on should restore them")
    }

    @MainActor
    func testBudgetProgressBarOptionsToggleFromBudgetViewMenu() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let progressBar = firstBudgetProgressBar(in: app)
        XCTAssertFalse(progressBar.exists, "Progress bars are seeded off")

        openBudgetViewMenu(app)
        let progress = app.buttons["budgetOptions.showBudgetProgressBars"]
        let inverse = app.buttons["budgetOptions.showInverseBudgetProgressBars"]
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertTrue(inverse.exists)
        XCTAssertFalse(progress.isSelected)
        XCTAssertFalse(inverse.isEnabled, "Inverse progress bars must be disabled while bars are hidden")

        progress.tap()
        XCTAssertTrue(progressBar.waitForExistence(timeout: 5),
                      "Turning Budget Progress Bars on should restore category bars")

        openBudgetViewMenu(app)
        let enabledInverse = app.buttons["budgetOptions.showInverseBudgetProgressBars"]
        XCTAssertTrue(enabledInverse.isEnabled, "Inverse progress bars should be enabled with bars")
        XCTAssertFalse(enabledInverse.isSelected)
        enabledInverse.tap()

        openBudgetViewMenu(app)
        let enabledBars = app.buttons["budgetOptions.showBudgetProgressBars"]
        XCTAssertTrue(enabledBars.isSelected)
        enabledBars.tap()
        XCTAssertTrue(progressBar.waitForNonExistence(timeout: 5),
                      "Turning Budget Progress Bars off should remove them from category rows")

        openBudgetViewMenu(app)
        let disabledInverse = app.buttons["budgetOptions.showInverseBudgetProgressBars"]
        XCTAssertFalse(disabledInverse.isEnabled)
        XCTAssertTrue(disabledInverse.isSelected,
                      "Disabling progress bars should preserve the inverse preference")
        app.buttons["budgetOptions.showBudgetProgressBars"].tap()

        openBudgetViewMenu(app)
        let restoredInverse = app.buttons["budgetOptions.showInverseBudgetProgressBars"]
        XCTAssertTrue(restoredInverse.isEnabled)
        XCTAssertTrue(restoredInverse.isSelected,
                      "Re-enabling progress bars should restore the inverse preference")
        restoredInverse.tap()

        openBudgetViewMenu(app)
        app.buttons["budgetOptions.showBudgetProgressBars"].tap()
    }

    @MainActor
    func testOverspentBadgeAndHideIncomeGroupTogglesFromBudgetViewMenu() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let incomeHeader = app.descendants(matching: .any)["budget.incomeGroupHeader"]
        scrollUntilHittable(incomeHeader, in: app, maxSwipes: 20, velocity: .slow)
        XCTAssertTrue(incomeHeader.exists && incomeHeader.isHittable,
                      "The demo budget should display the Income group")

        openBudgetViewMenu(app)
        let overspentBadge = app.buttons["budgetOptions.showOverspentBadge"]
        let hideIncome = app.buttons["budgetOptions.hideIncomeGroup"]
        XCTAssertTrue(overspentBadge.waitForExistence(timeout: 5))
        XCTAssertTrue(hideIncome.exists)
        XCTAssertTrue(overspentBadge.isSelected)
        XCTAssertFalse(hideIncome.isSelected)

        overspentBadge.tap()
        openBudgetViewMenu(app)
        let hiddenBadge = app.buttons["budgetOptions.showOverspentBadge"]
        XCTAssertFalse(hiddenBadge.isSelected, "Overspent Badge should be disabled")
        hiddenBadge.tap()

        openBudgetViewMenu(app)
        app.buttons["budgetOptions.hideIncomeGroup"].tap()
        XCTAssertTrue(incomeHeader.waitForNonExistence(timeout: 5),
                      "Hiding the Income group should remove it from the Budget screen")

        openBudgetViewMenu(app)
        let restoreIncome = app.buttons["budgetOptions.hideIncomeGroup"]
        XCTAssertTrue(restoreIncome.isSelected)
        restoreIncome.tap()
        scrollUntilHittable(incomeHeader, in: app, maxSwipes: 20, velocity: .slow)
        XCTAssertTrue(incomeHeader.exists && incomeHeader.isHittable,
                      "Turning Hide Income Group off should restore the Income group")
    }

    @MainActor
    func testShowBalanceImpactToggleCanBeChangedFromBudgetViewMenu() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        openBudgetViewMenu(app)
        let toggle = app.buttons["budgetOptions.showBalanceImpact"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(toggle.isSelected, "Show Balance Impact defaults on")
        toggle.tap()

        openBudgetViewMenu(app)
        let disabled = app.buttons["budgetOptions.showBalanceImpact"]
        XCTAssertFalse(disabled.isSelected, "Show Balance Impact should be off")
        disabled.tap()

        openBudgetViewMenu(app)
        XCTAssertTrue(app.buttons["budgetOptions.showBalanceImpact"].isSelected,
                      "Show Balance Impact should be restored")
    }

    @MainActor
    func testColorPickerOpensFromBudgetViewMenu() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        openBudgetViewMenu(app)
        app.buttons["budgetOptions.colorPicker"].tap()

        let navigationBar = app.navigationBars["Color picker"]
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 5),
                      "Color picker should open as a sheet from Budget View")

        let pickerIds = ["unassigned", "funded", "spending", "spent", "overspent"]
        for _ in 0..<5 where pickerIds.contains(where: { stateId in
            !app.descendants(matching: .any)["categoryStatusColorPicker.\(stateId)"].exists
        }) {
            app.swipeUp()
        }
        for stateId in pickerIds {
            let picker = app.descendants(matching: .any)["categoryStatusColorPicker.\(stateId)"]
            XCTAssertTrue(picker.waitForExistence(timeout: 5), "Color picker for \(stateId) not found")
            XCTAssertNotNil(picker.value, "Color picker \(stateId) should expose its selected color")
        }

        let resetButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'categoryStatusColorReset.'")
        )
        for _ in 0..<5 where resetButtons.count < 5 {
            app.swipeUp()
        }
        XCTAssertEqual(resetButtons.count, 5,
                       "All five category status reset controls should be present")

        let infoButton = app.buttons["categoryStatusColorPickerInfo"]
        for _ in 0..<5 where !infoButton.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(infoButton.isHittable, "Color picker info button should be reachable")
        infoButton.tap()

        let infoAlert = app.alerts["Color picker"]
        XCTAssertTrue(infoAlert.waitForExistence(timeout: 5), "Color picker info alert not found")
        XCTAssertTrue(
            infoAlert.staticTexts["Picked color will be used for both category status dots and progress bars."].exists,
            "Color picker info message not found"
        )
        infoAlert.buttons["OK"].tap()

        let done = app.buttons["budgetOptions.colorPickerDone"]
        for _ in 0..<5 where !done.exists {
            app.swipeDown()
        }
        XCTAssertTrue(done.isHittable, "Done should be available to dismiss the color picker sheet")
        done.tap()
        XCTAssertTrue(app.buttons["Budget options"].waitForExistence(timeout: 5),
                      "The sheet should return to the Budget screen")
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

        dismissMenu(app)
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
    func testGroupTotalsToggleChangesCompactGroupHeader() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        openStyleMenu(app)
        XCTAssertTrue(app.buttons["Compact"].waitForExistence(timeout: 5))
        app.buttons["Compact"].tap()

        let headerWithTotals = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Essentials, expanded, budgeted '")
        ).firstMatch
        XCTAssertTrue(
            headerWithTotals.waitForExistence(timeout: 10),
            "Compact group headers should include totals when Group Totals is enabled"
        )

        openBudgetViewMenu(app)
        let totals = app.buttons["Group Totals"]
        XCTAssertTrue(totals.waitForExistence(timeout: 5))
        XCTAssertTrue(totals.isSelected, "Group Totals starts enabled")
        totals.tap()

        let headerWithoutTotals = app.buttons["Essentials, expanded"]
        XCTAssertTrue(
            headerWithoutTotals.waitForExistence(timeout: 10),
            "Turning Group Totals off should leave the group header visible"
        )
        XCTAssertTrue(
            headerWithTotals.waitForNonExistence(timeout: 5),
            "Turning Group Totals off should remove the totals from the group header"
        )

        openBudgetViewMenu(app)
        let restoreTotals = app.buttons["Group Totals"]
        XCTAssertTrue(restoreTotals.waitForExistence(timeout: 5))
        XCTAssertFalse(restoreTotals.isSelected, "Group Totals should now be disabled")
        restoreTotals.tap()
        XCTAssertTrue(
            headerWithTotals.waitForExistence(timeout: 5),
            "Turning Group Totals back on should restore the totals"
        )
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
        dismissMenu(app)
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

        // Demo reseeding resets the viewed month to the current month. Rent's
        // current-month budget and fixed rent transaction are both
        // $1,850, so the category has exactly zero available and should be
        // hidden by Hide Spent Categories.
        let rentCategory = app.buttons["Details for Rent"].firstMatch
        XCTAssertTrue(
            rentCategory.waitForExistence(timeout: 10),
            "The demo's fully spent Rent category should start visible"
        )

        openBudgetViewMenu(app)
        let hideSpent = menuOption(app, "Hide Spent", accessibilityLabel: "Hide Spent Categories")
        XCTAssertTrue(hideSpent.waitForExistence(timeout: 5))
        XCTAssertFalse(hideSpent.isSelected, "Hide Spent Categories starts off")
        hideSpent.tap()

        XCTAssertTrue(
            rentCategory.waitForNonExistence(timeout: 5),
            "Enabling Hide Spent Categories should hide the fully spent Rent category"
        )

        openBudgetViewMenu(app)
        let enabled = menuOption(app, "Hide Spent", accessibilityLabel: "Hide Spent Categories")
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        XCTAssertTrue(enabled.isSelected, "Hide Spent Categories should now be enabled")
        enabled.tap()

        XCTAssertTrue(
            rentCategory.waitForExistence(timeout: 5),
            "Disabling Hide Spent Categories should restore the fully spent Rent category"
        )
    }

    @MainActor
    func testBudgetedAmountsToggleControlsBudgetRows() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let budgetedCaption = app.buttons["Edit budgeted amount for Groceries"].firstMatch
        XCTAssertTrue(
            budgetedCaption.waitForExistence(timeout: 10),
            "The demo budget should start with visible Budgeted captions"
        )

        openBudgetViewMenu(app)
        let budgeted = menuOption(app, "Show Budgeted", accessibilityLabel: "Budgeted Amounts")
        XCTAssertTrue(budgeted.waitForExistence(timeout: 5))
        budgeted.tap()
        XCTAssertTrue(
            budgetedCaption.waitForNonExistence(timeout: 5),
            "Turning Budgeted Amounts off should remove the caption from category rows"
        )
        XCTAssertTrue(
            app.buttons["Details for Groceries"].firstMatch.exists,
            "Hiding budgeted amounts must not hide the category itself"
        )

        openBudgetViewMenu(app)
        let restoreBudgeted = menuOption(app, "Show Budgeted", accessibilityLabel: "Budgeted Amounts")
        XCTAssertTrue(restoreBudgeted.waitForExistence(timeout: 5))
        restoreBudgeted.tap()
        XCTAssertTrue(
            budgetedCaption.waitForExistence(timeout: 5),
            "Turning Budgeted Amounts back on should restore the caption"
        )
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
        XCTAssertTrue(
            year.waitForNonExistence(timeout: 5),
            "selecting a month should dismiss the picker"
        )

        let optionsMenu = app.buttons["Budget options"]
        XCTAssertTrue(optionsMenu.waitForExistence(timeout: 5))
        optionsMenu.tap()
        XCTAssertFalse(app.buttons["Notes"].exists)
        XCTAssertTrue(app.buttons["budget.monthNote"].waitForExistence(timeout: 5),
                      "month notes should be a direct action in the ellipsis menu")
    }
}
