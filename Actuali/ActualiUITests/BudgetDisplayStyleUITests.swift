import XCTest

/// Budget layout preference (actios-96wa): the clean App Store-screenshot
/// look is the default, and the persisted preference switches the table to
/// the detailed PWA-style pills.
final class BudgetDisplayStyleUITests: XCTestCase {

    @MainActor private func budgetedCaption(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH 'Budgeted:'"))
            .firstMatch
    }

    @MainActor
    func testCleanStyleIsDefaultAndShowsCaptions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()

        app.tabBars.buttons["Budget"].tap()

        let groceries = app.buttons["Details for Groceries"].firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 10),
                      "demo data should show the Essentials categories")
        XCTAssertTrue(app.staticTexts["Budget Check-In"].exists,
                      "the month guidance should stay visible above the category groups")
        XCTAssertTrue(budgetedCaption(in: app).waitForExistence(timeout: 10),
                      "clean rows carry a 'Budgeted:' caption")
    }

    @MainActor
    func testOptionsMenuTogglesLayoutLive() throws {
        let app = XCUIApplication()
        // Seed clean explicitly: argument-domain values are volatile (the
        // init write-back was removed in actios-96wa), so this can't leak
        // into other tests, but a live tap below persists for real — start
        // from a known state regardless of what earlier runs left behind.
        app.launchArguments = ["-loadDemoData", "-budgetDisplayStyle", "clean"]
        app.launch()

        app.tabBars.buttons["Budget"].tap()
        XCTAssertTrue(budgetedCaption(in: app).waitForExistence(timeout: 10),
                      "starts in the clean layout")

        let optionsMenu = app.buttons["Budget options"]
        XCTAssertTrue(optionsMenu.waitForExistence(timeout: 10),
                      "the budget toolbar should offer the options menu")
        optionsMenu.tap()
        app.buttons["Detailed"].tap()
        XCTAssertFalse(budgetedCaption(in: app).waitForExistence(timeout: 5),
                       "detailed rows replace the captions")

        optionsMenu.tap()
        app.buttons["Clean"].tap()
        XCTAssertTrue(budgetedCaption(in: app).waitForExistence(timeout: 5),
                      "toggling back restores the clean rows")
    }

    @MainActor
    func testDetailedStyleShowsPillTableWithoutCaptions() throws {
        let app = XCUIApplication()
        // NSArgumentDomain: seeds the persisted preference for this launch.
        app.launchArguments = ["-loadDemoData", "-budgetDisplayStyle", "detailed"]
        app.launch()

        app.tabBars.buttons["Budget"].tap()

        let groceries = app.buttons["Details for Groceries"].firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 10),
                      "demo data should show the Essentials categories")
        XCTAssertFalse(budgetedCaption(in: app).exists,
                       "detailed rows show pill cells, not 'Budgeted:' captions")
    }

    @MainActor
    func testCategoryNameOpensActionableDetailSheet() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData", "-budgetDisplayStyle", "clean", "-initialTab", "1",
        ]
        app.launch()

        let groceries = app.buttons["Details for Groceries"].firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 10))
        groceries.tap()

        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Assign Money"].exists)
        XCTAssertTrue(app.buttons["This Month's Transactions"].exists)
        XCTAssertTrue(app.buttons["All Transactions"].exists)
        XCTAssertTrue(app.staticTexts["Quick Assign"].exists)
    }

    @MainActor
    func testCategoryActionsAndQuickAssignCanCollapse() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData", "-budgetDisplayStyle", "clean", "-initialTab", "1",
        ]
        app.launch()

        let groceries = app.buttons["Details for Groceries"].firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 10))
        groceries.tap()

        let actions = app.buttons["Actions, expanded"]
        let collapsedActions = app.buttons["Actions, collapsed"]
        if collapsedActions.waitForExistence(timeout: 2) {
            collapsedActions.tap()
        }
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Assign Money"].exists)
        actions.tap()
        XCTAssertTrue(collapsedActions.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Assign Money"].exists)

        let quickAssign = app.buttons["Quick Assign, expanded"]
        let collapsedQuickAssign = app.buttons["Quick Assign, collapsed"]
        if collapsedQuickAssign.waitForExistence(timeout: 2) {
            collapsedQuickAssign.tap()
        }
        XCTAssertTrue(quickAssign.waitForExistence(timeout: 10))
        quickAssign.tap()
        XCTAssertTrue(collapsedQuickAssign.waitForExistence(timeout: 5))

        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(groceries.waitForExistence(timeout: 5))
        groceries.tap()
        XCTAssertTrue(collapsedActions.waitForExistence(timeout: 10))
        XCTAssertTrue(collapsedQuickAssign.waitForExistence(timeout: 10))
    }

    @MainActor
    func testBudgetCheckInCanCollapse() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()

        app.tabBars.buttons["Budget"].tap()
        XCTAssertTrue(app.buttons["Details for Groceries"].firstMatch.waitForExistence(timeout: 10))

        let expanded = app.buttons["Budget Check-In, expanded"]
        let collapsed = app.buttons["Budget Check-In, collapsed"]
        if collapsed.waitForExistence(timeout: 2) {
            collapsed.tap()
        }
        XCTAssertTrue(expanded.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Resolve the important items before assigning the rest of the month."].exists)
        expanded.tap()
        XCTAssertTrue(collapsed.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Resolve the important items before assigning the rest of the month."].exists)
    }

    @MainActor
    func testBudgetCheckInCanFundAnUnassignedCategory() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "1"]
        app.launch()

        // Parking has no activity in the demo. Clearing its budget makes it
        // a real Not Funded check-in result through the normal write path.
        let editParking = app.buttons["Edit budgeted amount for Parking"]
        var scrollsLeft = 8
        while !editParking.isHittable && scrollsLeft > 0 {
            app.swipeUp()
            scrollsLeft -= 1
        }
        XCTAssertTrue(editParking.isHittable)
        editParking.tap()

        let amount = app.textFields.firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10))
        app.buttons["Save"].tap()
        XCTAssertTrue(amount.waitForNonExistence(timeout: 5))

        for _ in 0..<8 { app.swipeDown() }
        let notFunded = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'not funded'")
        ).firstMatch
        XCTAssertTrue(notFunded.waitForExistence(timeout: 10))
        notFunded.tap()

        let fundParking = app.buttons["Fund Parking"]
        XCTAssertTrue(fundParking.waitForExistence(timeout: 5),
                      "check-in result should expose a direct funding action")
        fundParking.tap()
        XCTAssertTrue(app.navigationBars["Parking"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Save"].exists)
    }
}
