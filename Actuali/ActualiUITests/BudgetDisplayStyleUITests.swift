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
        XCTAssertTrue(app.buttons["budgetFilter-all"].exists,
                      "the fixed check-in strip should stay visible above the category groups")
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
    func testCategoryNameOpensCompactEditor() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData", "-budgetDisplayStyle", "clean", "-initialTab", "1",
        ]
        app.launch()

        let groceries = app.buttons["Details for Groceries"].firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 10))
        groceries.tap()

        XCTAssertTrue(app.navigationBars["Edit Category"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["Category Name"].exists)
        XCTAssertTrue(app.staticTexts["Note"].exists)
        XCTAssertTrue(app.staticTexts["Quick Assign"].exists)
        XCTAssertFalse(app.buttons["This Month's Transactions"].exists)
        XCTAssertFalse(app.buttons["All Transactions"].exists)
        XCTAssertFalse(app.staticTexts["Actions"].exists)
    }

    @MainActor
    func testCheckInStripFiltersUnassignedCategoriesInPlace() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "1"]
        app.launch()

        // Parking has no activity in the demo. Clearing its budget makes it
        // a real Not Funded check-in result through the normal write path.
        let editParking = app.buttons["Edit budgeted amount for Parking"]
        // Slow swipes: the pinned summary and status strip leave a short List
        // viewport, and a full-velocity swipe scrolls Parking straight past
        // the hittable band and off the other side.
        var scrollsLeft = 20
        while !editParking.isHittable && scrollsLeft > 0 {
            app.swipeUp(velocity: .slow)
            scrollsLeft -= 1
        }
        XCTAssertTrue(editParking.isHittable, "Parking's edit button not reachable")
        editParking.tap()

        let amount = app.textFields.firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10))
        app.buttons["Save"].tap()
        XCTAssertTrue(amount.waitForNonExistence(timeout: 5))

        for _ in 0..<8 { app.swipeDown() }
        tapBudgetFilter(app, "unassigned")

        XCTAssertTrue(app.buttons["Details for Parking"].waitForExistence(timeout: 5),
                      "the horizontal check-in filter keeps matching categories in the budget table")
        XCTAssertFalse(app.buttons["Details for Groceries"].exists)
    }
}
