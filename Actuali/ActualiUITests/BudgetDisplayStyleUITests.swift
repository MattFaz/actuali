import XCTest

/// Budget layout preference (actios-96wa): the clean App Store-screenshot
/// look is the default, and the persisted preference switches the table to
/// the detailed PWA-style pills.
final class BudgetDisplayStyleUITests: XCTestCase {

    private func budgetedCaption(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH 'Budgeted:'"))
            .firstMatch
    }

    @MainActor
    func testCleanStyleIsDefaultAndShowsCaptions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()

        app.tabBars.buttons["tab.budget"].tap()

        let groceries = app.buttons["All transactions for Groceries"].firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 10),
                      "demo data should show the Essentials categories")
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

        app.tabBars.buttons["tab.budget"].tap()
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

        app.tabBars.buttons["tab.budget"].tap()

        let groceries = app.buttons["All transactions for Groceries"].firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 10),
                      "demo data should show the Essentials categories")
        XCTAssertFalse(budgetedCaption(in: app).exists,
                       "detailed rows show pill cells, not 'Budgeted:' captions")
    }
}
