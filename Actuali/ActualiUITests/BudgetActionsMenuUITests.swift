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
        for action in ["Check Templates", "Apply Budget Template",
                       "Overwrite with Budget Template", "End of Month Cleanup"] {
            XCTAssertFalse(app.buttons[action].exists,
                           "template actions should be hidden when goal templates are off")
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
        XCTAssertTrue(app.buttons["Clean"].waitForExistence(timeout: 5))
        for action in ["Copy last month's budget", "Set budgets to zero",
                       "Check Templates", "Apply Budget Template",
                       "Overwrite with Budget Template", "End of Month Cleanup"] {
            XCTAssertFalse(app.buttons[action].exists,
                           "'\(action)' moved to the Budget actions menu")
        }
    }

    @MainActor
    func testEnvelopeBudgetOffersTemplatesAndCleanup() {
        assertTemplateActions(tracking: false)
    }

    @MainActor
    func testTrackingBudgetOffersTemplatesWithoutCleanup() {
        assertTemplateActions(tracking: true)
    }

    @MainActor private func assertTemplateActions(tracking: Bool) {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "4"]
        if tracking {
            app.launchArguments.append("-loadTrackingDemoData")
        }
        app.launch()

        let budgetSettings = app.buttons["Budget View"]
        XCTAssertTrue(budgetSettings.waitForExistence(timeout: 10))
        budgetSettings.tap()
        let templates = app.switches["Budget Goal Templates"]
        for _ in 0..<5 where !templates.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(templates.isHittable)
        let toggle = templates.switches.firstMatch
        let control = toggle.exists ? toggle : templates
        control.tap()
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1"), object: control
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)

        app.tabBars.buttons["Budget"].tap()
        let actionsMenu = app.buttons["budget.actionsMenu"]
        XCTAssertTrue(actionsMenu.waitForExistence(timeout: 10))
        actionsMenu.tap()
        for action in ["Check Templates", "Apply Budget Template", "Overwrite with Budget Template"] {
            XCTAssertTrue(app.buttons[action].waitForExistence(timeout: 5))
        }
        XCTAssertEqual(app.buttons["End of Month Cleanup"].exists, !tracking)
    }
}
