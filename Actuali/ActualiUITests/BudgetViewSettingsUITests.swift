import XCTest

/// The Settings > Budget View controls are a second public surface for the
/// Budget tab's presentation preferences. These checks exercise that surface
/// end to end instead of relying on the Budget options menu's coverage.
final class BudgetViewSettingsUITests: XCTestCase {

    @MainActor
    private func launchSettings(
        budgetDisplayStyle: String = "clean",
        showGroupTotals: Bool = true,
        showBudgetCheckInStrip: Bool = true,
        hideZeroBudgetCategories: Bool = false,
        showCategoryStatusDots: Bool = true,
        showBudgetProgressBars: Bool = true
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-initialTab", "4",
            "-budgetDisplayStyle", budgetDisplayStyle,
            "-showGroupTotals", showGroupTotals ? "YES" : "NO",
            "-showBudgetCheckInStrip", showBudgetCheckInStrip ? "YES" : "NO",
            "-hideZeroBudgetCategories", hideZeroBudgetCategories ? "YES" : "NO",
            "-showCategoryStatusDots", showCategoryStatusDots ? "YES" : "NO",
            "-showBudgetProgressBars", showBudgetProgressBars ? "YES" : "NO",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func openBudgetViewSettings(in app: XCUIApplication) {
        app.tabBars.buttons["More"].tap()
        if app.navigationBars["Budget View"].waitForExistence(timeout: 2) {
            return
        }

        let row = app.buttons["Budget View"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Budget View settings row not found")
        row.tap()
        XCTAssertTrue(app.navigationBars["Budget View"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func selectViewStyle(_ style: String, in app: XCUIApplication) {
        let picker = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'View Style'")
        ).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "View Style picker not found")
        picker.tap()

        let option = app.buttons[style]
        XCTAssertTrue(option.waitForExistence(timeout: 5), "\(style) option not found")
        option.tap()
        XCTAssertTrue(app.navigationBars["Budget View"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func tapSwitch(_ toggle: XCUIElement) {
        let control = toggle.switches.firstMatch
        (control.exists ? control : toggle).tap()
    }

    @MainActor
    private func firstBudgetProgressBar(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label MATCHES[c] '.*spent [0-9]+ percent'")
        ).firstMatch
    }

    @MainActor
    func testViewStyleControlsGroupTotalsAvailabilityAndPresentation() throws {
        let app = launchSettings()
        openBudgetViewSettings(in: app)

        let groupTotals = app.switches["Group Totals"]
        XCTAssertTrue(groupTotals.waitForExistence(timeout: 5), "Group Totals toggle not found")
        XCTAssertFalse(groupTotals.isEnabled, "Clean view should disable Group Totals")

        selectViewStyle("Detailed", in: app)
        XCTAssertTrue(groupTotals.isEnabled, "Detailed view should enable Group Totals")

        app.tabBars.buttons["Budget"].tap()
        let headerWithTotals = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Essentials, expanded, budgeted '")
        ).firstMatch
        XCTAssertTrue(
            headerWithTotals.waitForExistence(timeout: 10),
            "Detailed view should show totals in the group header"
        )

        openBudgetViewSettings(in: app)
        tapSwitch(groupTotals)
        app.tabBars.buttons["Budget"].tap()

        XCTAssertTrue(app.buttons["Essentials, expanded"].waitForExistence(timeout: 10))
        XCTAssertFalse(headerWithTotals.exists, "Turning Group Totals off should remove the totals")
    }

    @MainActor
    func testStatusFiltersToggleControlsTheBudgetCheckInStrip() throws {
        let app = launchSettings(showBudgetCheckInStrip: true)
        openBudgetViewSettings(in: app)

        let toggle = app.switches["Status Filters"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Status Filters toggle not found")
        tapSwitch(toggle)

        app.tabBars.buttons["Budget"].tap()
        let allFilter = app.buttons["budgetFilter-all"]
        XCTAssertTrue(
            allFilter.waitForNonExistence(timeout: 5),
            "Turning Status Filters off in Settings should hide the check-in strip"
        )

        openBudgetViewSettings(in: app)
        tapSwitch(toggle)
        app.tabBars.buttons["Budget"].tap()
        XCTAssertTrue(
            allFilter.waitForExistence(timeout: 5),
            "Turning Status Filters back on should restore the check-in strip"
        )
    }

    @MainActor
    func testHideSpentCategoriesToggleControlsBudgetRows() throws {
        let app = launchSettings(hideZeroBudgetCategories: false)
        openBudgetViewSettings(in: app)

        let toggle = app.switches["Hide Spent Categories"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Hide Spent Categories toggle not found")

        app.tabBars.buttons["Budget"].tap()
        let spentCategory = app.buttons["Details for Rent"].firstMatch
        XCTAssertTrue(
            spentCategory.waitForExistence(timeout: 10),
            "The demo's fully spent Rent category should start visible"
        )

        openBudgetViewSettings(in: app)
        tapSwitch(toggle)
        app.tabBars.buttons["Budget"].tap()
        XCTAssertTrue(
            spentCategory.waitForNonExistence(timeout: 5),
            "Turning Hide Spent Categories on should remove fully spent rows"
        )

        openBudgetViewSettings(in: app)
        tapSwitch(toggle)
        app.tabBars.buttons["Budget"].tap()
        XCTAssertTrue(
            spentCategory.waitForExistence(timeout: 5),
            "Turning Hide Spent Categories off should restore fully spent rows"
        )
    }

    @MainActor
    func testBudgetProgressBarsToggleControlsBudgetRows() throws {
        let app = launchSettings(showBudgetProgressBars: true)
        openBudgetViewSettings(in: app)

        let toggle = app.switches["Budget Progress Bars"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Budget Progress Bars toggle not found")

        app.tabBars.buttons["Budget"].tap()
        let progressBar = firstBudgetProgressBar(in: app)
        XCTAssertTrue(
            progressBar.waitForExistence(timeout: 10),
            "The demo budget should start with visible category progress bars"
        )

        openBudgetViewSettings(in: app)
        tapSwitch(toggle)
        app.tabBars.buttons["Budget"].tap()
        XCTAssertTrue(
            progressBar.waitForNonExistence(timeout: 5),
            "Turning Budget Progress Bars off should remove them from category rows"
        )

        openBudgetViewSettings(in: app)
        tapSwitch(toggle)
        app.tabBars.buttons["Budget"].tap()
        XCTAssertTrue(
            firstBudgetProgressBar(in: app).waitForExistence(timeout: 5),
            "Turning Budget Progress Bars back on should restore them"
        )
    }

    @MainActor
    func testCategoryStatusDotsToggleControlsBudgetRows() throws {
        let app = launchSettings(showCategoryStatusDots: true)
        openBudgetViewSettings(in: app)

        let toggle = app.switches["Category Status Dots"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Category Status Dots toggle not found")

        app.tabBars.buttons["Budget"].tap()
        let statusDot = app.descendants(matching: .any)["categoryStatusDot"].firstMatch
        XCTAssertTrue(
            statusDot.waitForExistence(timeout: 10),
            "The demo budget should start with visible category status dots"
        )

        openBudgetViewSettings(in: app)
        tapSwitch(toggle)
        app.tabBars.buttons["Budget"].tap()
        XCTAssertTrue(
            statusDot.waitForNonExistence(timeout: 5),
            "Turning Category Status Dots off should remove them from category rows"
        )

        openBudgetViewSettings(in: app)
        tapSwitch(toggle)
        app.tabBars.buttons["Budget"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["categoryStatusDot"].firstMatch.waitForExistence(timeout: 5),
            "Turning Category Status Dots back on should restore them"
        )
    }
}
