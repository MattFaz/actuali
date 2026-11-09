import XCTest

/// The ellipsis menu groups style, the Budget View sheet, and month actions.
final class BudgetOptionsMenuUITests: XCTestCase {
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
        let budgetView = app.buttons["Budget View"]
        XCTAssertTrue(budgetView.waitForExistence(timeout: 5))
        budgetView.tap()
        XCTAssertTrue(app.navigationBars["Budget View"].waitForExistence(timeout: 5))
    }

    @MainActor private func closeBudgetViewSheet(_ app: XCUIApplication) {
        let done = app.buttons["budgetView.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
    }

    @MainActor private func budgetViewToggle(
        _ app: XCUIApplication,
        _ identifier: String
    ) -> XCUIElement {
        let toggle = app.switches[identifier]
        for _ in 0..<12 where !toggle.exists {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "Budget View toggle \(identifier) should be present")
        scrollUntilHittable(toggle, in: app, maxSwipes: 12, velocity: .slow)
        XCTAssertTrue(toggle.isHittable, "Budget View toggle \(identifier) should be reachable")
        return toggle
    }

    @MainActor private func isOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? String) == "1"
    }

    @MainActor private func tapSwitch(_ toggle: XCUIElement) {
        let previousValue = toggle.value as? String
        tapControl(toggle) {
            (toggle.value as? String) != previousValue
        }
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
    func testBudgetViewSheetOffersEveryDisplayOption() {
        let app = XCUIApplication()
        launchBudgetTab(app)
        openBudgetViewMenu(app)

        let expectations: [(String, String, Bool, Bool)] = [
            ("Show Overview", "budgetView.showOverview", true, true),
            ("Show Budgeted", "budgetView.showBudgetedAmounts", true, true),
            ("Show Spent", "budgetView.showCompactSpentColumn", false, false),
            ("Group Totals", "budgetView.showGroupTotals", true, false),
            ("Status Filters", "budgetView.showBudgetCheckInStrip", true, true),
            ("Hide Spent", "budgetView.hideZeroBudgetCategories", false, true),
            ("Category Status Dots", "budgetView.showCategoryStatusDots", true, true),
            ("Budget Progress Bars", "budgetView.showBudgetProgressBars", false, true),
            ("Inverse Progress Bars", "budgetView.showInverseBudgetProgressBars", false, false),
            ("Overspent Badge", "budgetView.showOverspentBadge", true, true),
            ("Hide Income Group", "budgetView.hideIncomeGroup", false, true),
        ]
        for (name, identifier, expectedValue, expectedEnabled) in expectations {
            let toggle = budgetViewToggle(app, identifier)
            XCTAssertEqual(isOn(toggle), expectedValue, "\(name) should have its seeded value")
            XCTAssertEqual(toggle.isEnabled, expectedEnabled, "\(name) should have its expected availability")
        }

        let picker = app.descendants(matching: .any)["categoryStatusColorPicker.unassigned"]
        for _ in 0..<8 where !picker.exists {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(picker.waitForExistence(timeout: 5),
                      "Category status color pickers should appear below the display toggles")
        closeBudgetViewSheet(app)
    }

    @MainActor
    func testCategoryStatusDotsToggleControlsBudgetRows() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let statusDot = app.descendants(matching: .any)["categoryStatusDot"].firstMatch
        XCTAssertTrue(statusDot.waitForExistence(timeout: 10),
                      "The demo budget should start with visible category status dots")

        openBudgetViewMenu(app)
        let toggle = budgetViewToggle(app, "budgetView.showCategoryStatusDots")
        XCTAssertTrue(isOn(toggle), "Category Status Dots starts enabled")
        tapSwitch(toggle)
        closeBudgetViewSheet(app)

        XCTAssertTrue(statusDot.waitForNonExistence(timeout: 5),
                      "Turning Category Status Dots off should remove them from category rows")

        openBudgetViewMenu(app)
        let restore = budgetViewToggle(app, "budgetView.showCategoryStatusDots")
        XCTAssertFalse(isOn(restore), "Category Status Dots should now be disabled")
        tapSwitch(restore)
        closeBudgetViewSheet(app)

        XCTAssertTrue(statusDot.waitForExistence(timeout: 5),
                      "Turning Category Status Dots back on should restore them")
    }

    @MainActor
    func testBudgetProgressBarOptionsToggleFromBudgetViewSheet() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let progressBar = firstBudgetProgressBar(in: app)
        XCTAssertFalse(progressBar.exists, "Progress bars are seeded off")

        openBudgetViewMenu(app)
        let progress = budgetViewToggle(app, "budgetView.showBudgetProgressBars")
        XCTAssertFalse(isOn(progress))
        tapSwitch(progress)

        let inverse = budgetViewToggle(app, "budgetView.showInverseBudgetProgressBars")
        XCTAssertTrue(inverse.isEnabled)
        XCTAssertFalse(isOn(inverse))
        tapSwitch(inverse)
        closeBudgetViewSheet(app)
        XCTAssertTrue(progressBar.waitForExistence(timeout: 5),
                      "Enabling progress and inverse mode should restore category bars")

        openBudgetViewMenu(app)
        let enabledBars = budgetViewToggle(app, "budgetView.showBudgetProgressBars")
        XCTAssertTrue(isOn(enabledBars))
        tapSwitch(enabledBars)
        closeBudgetViewSheet(app)
        XCTAssertTrue(progressBar.waitForNonExistence(timeout: 5),
                      "Turning Budget Progress Bars off should remove them from category rows")

        openBudgetViewMenu(app)
        let disabledInverse = budgetViewToggle(app, "budgetView.showInverseBudgetProgressBars")
        XCTAssertFalse(disabledInverse.isEnabled)
        XCTAssertTrue(isOn(disabledInverse),
                      "Disabling progress bars should preserve the inverse preference")
        let restoredBars = budgetViewToggle(app, "budgetView.showBudgetProgressBars")
        tapSwitch(restoredBars)
        let restoredInverse = budgetViewToggle(app, "budgetView.showInverseBudgetProgressBars")
        XCTAssertTrue(restoredInverse.isEnabled)
        XCTAssertTrue(isOn(restoredInverse),
                      "Re-enabling progress bars should restore the inverse preference")
        tapSwitch(restoredInverse)
        let finalBars = budgetViewToggle(app, "budgetView.showBudgetProgressBars")
        tapSwitch(finalBars)
        closeBudgetViewSheet(app)
    }

    @MainActor
    func testOverspentBadgeAndHideIncomeGroupTogglesFromBudgetViewSheet() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let incomeHeader = app.descendants(matching: .any)["budget.incomeGroupHeader"]
        scrollUntilHittable(incomeHeader, in: app, maxSwipes: 20, velocity: .slow)
        XCTAssertTrue(incomeHeader.exists && incomeHeader.isHittable,
                      "The demo budget should display the Income group")

        openBudgetViewMenu(app)
        let overspentBadge = budgetViewToggle(app, "budgetView.showOverspentBadge")
        XCTAssertTrue(isOn(overspentBadge))
        tapSwitch(overspentBadge)
        XCTAssertFalse(isOn(overspentBadge), "Overspent Badge should be disabled")
        tapSwitch(overspentBadge)

        let hideIncome = budgetViewToggle(app, "budgetView.hideIncomeGroup")
        XCTAssertFalse(isOn(hideIncome))
        tapSwitch(hideIncome)
        closeBudgetViewSheet(app)
        XCTAssertTrue(incomeHeader.waitForNonExistence(timeout: 5),
                      "Hiding the Income group should remove it from the Budget screen")

        openBudgetViewMenu(app)
        let restoreIncome = budgetViewToggle(app, "budgetView.hideIncomeGroup")
        XCTAssertTrue(isOn(restoreIncome))
        tapSwitch(restoreIncome)
        closeBudgetViewSheet(app)
        scrollUntilHittable(incomeHeader, in: app, maxSwipes: 20, velocity: .slow)
        XCTAssertTrue(incomeHeader.exists && incomeHeader.isHittable,
                      "Turning Hide Income Group off should restore the Income group")
    }

    @MainActor
    func testBudgetViewSheetContainsCategoryStatusColorPickers() {
        let app = XCUIApplication()
        launchBudgetTab(app)
        openBudgetViewMenu(app)

        let navigationBar = app.navigationBars["Budget View"]
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 5),
                      "Budget View options should open as one sheet")

        let pickerIds = ["unassigned", "funded", "spending", "spent", "overspent"]
        for stateId in pickerIds {
            let picker = app.descendants(matching: .any)["categoryStatusColorPicker.\(stateId)"]
            for _ in 0..<8 where !picker.exists {
                app.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(picker.waitForExistence(timeout: 5), "Color picker for \(stateId) not found")
            XCTAssertNotNil(picker.value, "Color picker \(stateId) should expose its selected color")
        }

        let resetButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'categoryStatusColorReset.'")
        )
        for _ in 0..<8 where resetButtons.count < 5 {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertEqual(resetButtons.count, 5,
                       "All five category status reset controls should be present")

        let infoButton = app.buttons["categoryStatusColorPickerInfo"]
        for _ in 0..<8 where !infoButton.isHittable {
            app.swipeUp(velocity: .slow)
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
        closeBudgetViewSheet(app)
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
        let spent = budgetViewToggle(app, "budgetView.showCompactSpentColumn")
        XCTAssertTrue(spent.isEnabled)
        XCTAssertFalse(isOn(spent), "launch argument seeds Show Spent off")
        let totals = budgetViewToggle(app, "budgetView.showGroupTotals")
        XCTAssertTrue(totals.isEnabled)
        XCTAssertTrue(isOn(totals), "launch argument seeds Group Totals on")
        XCTAssertFalse(app.buttons["Progress Indicators"].exists)
        closeBudgetViewSheet(app)

        openStyleMenu(app)
        app.buttons["Clean"].tap()
        openBudgetViewMenu(app)
        let cleanOverview = budgetViewToggle(app, "budgetView.showOverview")
        XCTAssertTrue(isOn(cleanOverview))
        let cleanSpent = budgetViewToggle(app, "budgetView.showCompactSpentColumn")
        XCTAssertFalse(cleanSpent.isEnabled)
        let cleanTotals = budgetViewToggle(app, "budgetView.showGroupTotals")
        XCTAssertFalse(cleanTotals.isEnabled)
        XCTAssertFalse(app.buttons["Progress Indicators"].exists)
        closeBudgetViewSheet(app)
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
        let totals = budgetViewToggle(app, "budgetView.showGroupTotals")
        XCTAssertTrue(isOn(totals), "Group Totals starts enabled")
        tapSwitch(totals)
        closeBudgetViewSheet(app)

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
        let restoreTotals = budgetViewToggle(app, "budgetView.showGroupTotals")
        XCTAssertFalse(isOn(restoreTotals), "Group Totals should now be disabled")
        tapSwitch(restoreTotals)
        closeBudgetViewSheet(app)
        XCTAssertTrue(
            headerWithTotals.waitForExistence(timeout: 5),
            "Turning Group Totals back on should restore the totals"
        )
    }

    @MainActor
    func testCleanOverviewTogglesFromBudgetViewSheet() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let topBox = app.otherElements["budget.topBox"]
        XCTAssertTrue(topBox.waitForExistence(timeout: 10), "the clean summary shows by default")

        openBudgetViewMenu(app)
        let overview = budgetViewToggle(app, "budgetView.showOverview")
        XCTAssertTrue(isOn(overview))
        tapSwitch(overview)
        closeBudgetViewSheet(app)
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
        let compactOverview = budgetViewToggle(app, "budgetView.showOverview")
        XCTAssertTrue(isOn(compactOverview), "Show Overview defaults on for Compact")
        closeBudgetViewSheet(app)
        openStyleMenu(app)
        app.buttons["Clean"].tap()

        openBudgetViewMenu(app)
        let cleanOverview = budgetViewToggle(app, "budgetView.showOverview")
        XCTAssertFalse(isOn(cleanOverview), "Clean's hidden overview preference survives style changes")
        tapSwitch(cleanOverview)
        closeBudgetViewSheet(app)
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
        let overview = budgetViewToggle(app, "budgetView.showOverview")
        tapSwitch(overview)
        closeBudgetViewSheet(app)
        let row = app.buttons["budget.readyToBudget"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.hasPrefix("Overbudgeted,"), "negative funds must not read Ready to Budget")

        openBudgetViewMenu(app)
        let restoreOverview = budgetViewToggle(app, "budgetView.showOverview")
        tapSwitch(restoreOverview)
        closeBudgetViewSheet(app)
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
    func testStatusFilterStripTogglesFromBudgetViewSheet() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let allChip = app.buttons["budgetFilter-all"]
        openBudgetViewMenu(app)
        let statusFilters = budgetViewToggle(app, "budgetView.showBudgetCheckInStrip")
        let startedShown = isOn(statusFilters)
        XCTAssertEqual(allChip.exists, startedShown,
                       "the strip's visibility should match the sheet toggle")

        tapSwitch(statusFilters)
        closeBudgetViewSheet(app)
        if startedShown {
            XCTAssertTrue(allChip.waitForNonExistence(timeout: 5),
                          "turning the toggle off should hide the strip")
        } else {
            XCTAssertTrue(allChip.waitForExistence(timeout: 5),
                          "turning the toggle on should show the strip")
        }

        openBudgetViewMenu(app)
        let toggled = budgetViewToggle(app, "budgetView.showBudgetCheckInStrip")
        tapSwitch(toggled)
        closeBudgetViewSheet(app)
        XCTAssertEqual(allChip.waitForExistence(timeout: 5), startedShown,
                       "toggling back should restore the original state")
    }

    @MainActor
    func testHideSpentCategoriesTogglesFromBudgetViewSheet() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let rentCategory = app.buttons["Details for Rent"].firstMatch
        XCTAssertTrue(
            rentCategory.waitForExistence(timeout: 10),
            "The demo's fully spent Rent category should start visible"
        )

        openBudgetViewMenu(app)
        let hideSpent = budgetViewToggle(app, "budgetView.hideZeroBudgetCategories")
        XCTAssertFalse(isOn(hideSpent), "Hide Spent Categories starts off")
        tapSwitch(hideSpent)
        closeBudgetViewSheet(app)
        XCTAssertTrue(
            rentCategory.waitForNonExistence(timeout: 5),
            "Enabling Hide Spent Categories should hide the fully spent Rent category"
        )

        openBudgetViewMenu(app)
        let enabled = budgetViewToggle(app, "budgetView.hideZeroBudgetCategories")
        XCTAssertTrue(isOn(enabled), "Hide Spent Categories should now be enabled")
        tapSwitch(enabled)
        closeBudgetViewSheet(app)
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
        let budgeted = budgetViewToggle(app, "budgetView.showBudgetedAmounts")
        tapSwitch(budgeted)
        closeBudgetViewSheet(app)
        XCTAssertTrue(
            budgetedCaption.waitForNonExistence(timeout: 5),
            "Turning Budgeted Amounts off should remove the caption from category rows"
        )
        XCTAssertTrue(
            app.buttons["Details for Groceries"].firstMatch.exists,
            "Hiding budgeted amounts must not hide the category itself"
        )

        openBudgetViewMenu(app)
        let restoreBudgeted = budgetViewToggle(app, "budgetView.showBudgetedAmounts")
        tapSwitch(restoreBudgeted)
        closeBudgetViewSheet(app)
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
