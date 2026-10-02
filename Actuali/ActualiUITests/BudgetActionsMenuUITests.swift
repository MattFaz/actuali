import XCTest

/// The Budget tab's sparkles button holds the actions that change the month's
/// budget; the `…` options menu keeps only view options.
final class BudgetActionsMenuUITests: XCTestCase {
    @MainActor private func launchBudgetTab(_ app: XCUIApplication) {
        app.launchArguments = ["-loadDemoData", "-budgetDisplayStyle", "clean"]
        app.launch()
        app.tabBars.buttons["Budget"].tap()
    }

    @MainActor
    func testActionsMenuOffersTheBudgetActions() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let actionsMenu = app.buttons["Budget actions"]
        XCTAssertTrue(actionsMenu.waitForExistence(timeout: 10))
        actionsMenu.tap()

        for action in ["Copy last month's budget", "Set budgets to zero"] {
            XCTAssertTrue(app.buttons[action].waitForExistence(timeout: 5),
                          "the actions menu should offer '\(action)'")
        }
    }

    @MainActor
    func testOptionsMenuNoLongerHoldsTheBudgetActions() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let optionsMenu = app.buttons["Budget options"]
        XCTAssertTrue(optionsMenu.waitForExistence(timeout: 10))
        optionsMenu.tap()

        // A view option is there, so the menu has opened and the absences
        // below are real.
        XCTAssertTrue(app.buttons["Expand All Groups"].waitForExistence(timeout: 5))
        for action in ["Copy last month's budget", "Set budgets to zero",
                       "Check Templates", "Apply Budget Template",
                       "Overwrite with Budget Template", "End of Month Cleanup"] {
            XCTAssertFalse(app.buttons[action].exists,
                           "'\(action)' moved to the Budget actions menu")
        }
    }
}
