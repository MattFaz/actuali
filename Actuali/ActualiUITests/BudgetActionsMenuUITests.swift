import XCTest

/// The Actuali-mark menu handles category creation, reordering and hidden-category visibility.
final class BudgetActionsMenuUITests: XCTestCase {
    @MainActor private func launchBudgetTab(_ app: XCUIApplication) {
        app.launchArguments = [
            "-loadDemoData",
            "-initialTab", "1",
            "-budgetDisplayStyle", "clean",
            "-showHiddenCategories", "NO",
        ]
        app.launch()
        app.tabBars.buttons["Budget"].tap()
    }

    @MainActor private func menuOption(
        _ app: XCUIApplication,
        _ title: String,
        accessibilityLabel: String
    ) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@", [title, accessibilityLabel])).firstMatch
    }

    @MainActor
    func testActualiMenuOffersCreationReorderingAndHiddenCategories() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let logoMenu = app.buttons["Actuali menu"]
        XCTAssertTrue(logoMenu.waitForExistence(timeout: 10))
        logoMenu.tap()

        for action in ["New Category", "Reorder Items", "Expand Groups", "Collapse Groups"] {
            XCTAssertTrue(app.buttons[action].waitForExistence(timeout: 5),
                          "the Actuali menu should offer '\(action)'")
        }
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label IN %@", ["New Group", "New Category Group"])
        ).firstMatch.waitForExistence(timeout: 5), "the Actuali menu should offer New Group")
        let hiddenCategories = menuOption(app, "Hidden Categories", accessibilityLabel: "Show Hidden Categories")
        XCTAssertTrue(hiddenCategories.waitForExistence(timeout: 5))
        XCTAssertFalse(hiddenCategories.isSelected, "launch arguments start hidden categories off")

        for action in ["Copy last month's budget", "Set budgets to zero", "Check Templates",
                       "Apply Budget Template", "Overwrite with Budget Template", "End of Month Cleanup"] {
            XCTAssertFalse(app.buttons[action].exists,
                           "'\(action)' belongs in the Actions submenu under the ellipsis")
        }
    }

    @MainActor
    func testActualiMenuCanSelectCurrentAndOtherBudgets() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-initialTab", "1",
            "-budgetDisplayStyle", "clean",
            "-connectedServerSettings",
            "-budgetSelectionFixture",
        ]
        app.launch()
        app.tabBars.buttons["Budget"].tap()

        let logoMenu = app.buttons["Actuali menu"]
        XCTAssertTrue(logoMenu.waitForExistence(timeout: 10))
        logoMenu.tap()

        let budgetPicker = app.buttons["budgetActions.budgetPicker"]
        XCTAssertTrue(budgetPicker.waitForExistence(timeout: 5),
                      "the Actuali menu should show the current budget selector")
        budgetPicker.tap()

        // Labels, not identifiers: iOS 27 drops identifiers on menu items.
        let currentBudget = app.buttons["Demo Budget"]
        let otherBudget = app.buttons["Other Budget"]
        let encryptedBudget = app.buttons["Encrypted Budget"]
        XCTAssertTrue(currentBudget.waitForExistence(timeout: 5))
        // isSelected would be the direct check, but iOS 27 drops traits on
        // menu items; the open budget is the one row that can't be picked.
        XCTAssertFalse(currentBudget.isEnabled,
                       "the current budget should not be selectable again")
        XCTAssertTrue(otherBudget.waitForExistence(timeout: 5),
                      "the selector should offer other server budgets")
        XCTAssertTrue(encryptedBudget.waitForExistence(timeout: 5),
                      "encrypted budgets should also be selectable")
        XCTAssertTrue(otherBudget.isEnabled)
        XCTAssertTrue(encryptedBudget.isEnabled)
    }

    @MainActor
    func testBudgetSelectorRemainsVisibleWithoutActiveConnection() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-initialTab", "1",
            "-budgetDisplayStyle", "clean",
            "-budgetSelectionFixture",
        ]
        app.launch()
        app.tabBars.buttons["Budget"].tap()

        let logoMenu = app.buttons["Actuali menu"]
        XCTAssertTrue(logoMenu.waitForExistence(timeout: 10))
        logoMenu.tap()

        let budgetPicker = app.buttons["budgetActions.budgetPicker"]
        XCTAssertTrue(budgetPicker.waitForExistence(timeout: 5),
                      "the current budget should remain selectable from the logo menu")
        XCTAssertTrue(budgetPicker.label.hasPrefix("Current Budget"),
                      "the selector should identify itself when offline")
        XCTAssertTrue(budgetPicker.label.contains("Demo Budget"),
                      "the selector should include the loaded budget name when offline")
    }

    @MainActor
    func testHiddenCategoriesToggleLivesInActualiMenu() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let logoMenu = app.buttons["Actuali menu"]
        XCTAssertTrue(logoMenu.waitForExistence(timeout: 10))
        logoMenu.tap()
        let hiddenCategories = menuOption(app, "Hidden Categories", accessibilityLabel: "Show Hidden Categories")
        XCTAssertTrue(hiddenCategories.waitForExistence(timeout: 5))
        XCTAssertFalse(hiddenCategories.isSelected)
        hiddenCategories.tap()

        logoMenu.tap()
        let enabled = menuOption(app, "Hidden Categories", accessibilityLabel: "Show Hidden Categories")
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        XCTAssertTrue(enabled.isSelected, "tapping the logo-menu toggle shows hidden categories")
        enabled.tap()

        logoMenu.tap()
        XCTAssertFalse(menuOption(
            app, "Hidden Categories", accessibilityLabel: "Show Hidden Categories"
        ).isSelected, "restore the seeded preference for other tests")
    }

    @MainActor
    func testEllipsisActionsAreGroupedAndTemplateOptionsRemainVisible() {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let optionsMenu = app.buttons["Budget options"]
        XCTAssertTrue(optionsMenu.waitForExistence(timeout: 10))
        optionsMenu.tap()
        for submenu in ["Style", "Budget View", "Actions"] {
            XCTAssertTrue(app.buttons[submenu].waitForExistence(timeout: 5),
                          "the ellipsis should offer a '\(submenu)' submenu")
        }

        app.buttons["Actions"].tap()
        for action in ["Copy last month's budget", "Set budgets to zero", "Check Templates",
                       "Apply Budget Template", "Overwrite with Budget Template", "End of Month Cleanup"] {
            let option = app.buttons[action]
            XCTAssertTrue(option.waitForExistence(timeout: 5),
                          "'\(action)' should be available in the Actions submenu")
        }
        for action in ["Check Templates", "Apply Budget Template", "Overwrite with Budget Template", "End of Month Cleanup"] {
            XCTAssertFalse(app.buttons[action].isEnabled,
                           "'\(action)' stays visible but is disabled until Budget Goal Templates is enabled")
        }
    }

    @MainActor
    func testEnvelopeBudgetOffersAllTemplateActionsWhenEnabled() {
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
        XCTAssertTrue(app.navigationBars["Budget View"].waitForExistence(timeout: 5))
        let templates = app.descendants(matching: .any)["budgetViewSettings.goalTemplates"]
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
        let optionsMenu = app.buttons["Budget options"]
        XCTAssertTrue(optionsMenu.waitForExistence(timeout: 10))
        optionsMenu.tap()
        app.buttons["Actions"].tap()
        for action in ["Copy last month's budget", "Set budgets to zero", "Check Templates",
                       "Apply Budget Template", "Overwrite with Budget Template"] {
            let option = app.buttons[action]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            XCTAssertTrue(option.isEnabled, "'\(action)' should be enabled when Goal Templates is on")
        }
        let cleanup = app.buttons["End of Month Cleanup"]
        XCTAssertEqual(cleanup.exists, !tracking)
        if !tracking {
            XCTAssertTrue(cleanup.isEnabled)
        }
    }
}
