import XCTest

/// The Budget tab's consolidated view-options menu (GH #157): layout,
/// expand/collapse and the spent-category filter all sit behind one
/// navigation-bar button.
final class BudgetOptionsMenuUITests: XCTestCase {

    @MainActor private func launchBudgetTab(_ app: XCUIApplication) {
        // Seed the persisted toggles: they survive between launches for real
        // in the simulator, so start from a known state whatever earlier runs
        // left behind.
        app.launchArguments = [
            "-loadDemoData",
            "-budgetDisplayStyle", "clean",
            "-hideZeroBudgetCategories", "NO",
        ]
        app.launch()
        app.tabBars.buttons["Budget"].tap()
    }

    @MainActor
    func testMenuOffersEveryBudgetViewOption() throws {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let optionsMenu = app.buttons["Budget options"]
        XCTAssertTrue(optionsMenu.waitForExistence(timeout: 10))
        optionsMenu.tap()

        for option in ["Clean", "Detailed", "Expand All Groups",
                       "Collapse All Groups", "Hide Spent Categories"] {
            XCTAssertTrue(app.buttons[option].waitForExistence(timeout: 5),
                          "the options menu should offer '\(option)'")
        }
    }

    @MainActor
    func testHideSpentCategoriesTogglesFromTheMenu() throws {
        let app = XCUIApplication()
        launchBudgetTab(app)

        let optionsMenu = app.buttons["Budget options"]
        XCTAssertTrue(optionsMenu.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["All transactions for Groceries"].firstMatch
            .waitForExistence(timeout: 10),
                      "demo data should show the Essentials categories")

        optionsMenu.tap()
        let hideSpent = app.buttons["Hide Spent Categories"]
        XCTAssertTrue(hideSpent.waitForExistence(timeout: 5))
        XCTAssertFalse(hideSpent.isSelected, "the filter starts off")
        hideSpent.tap()

        // Reopen: a checked menu toggle reports as selected.
        optionsMenu.tap()
        XCTAssertTrue(hideSpent.waitForExistence(timeout: 5))
        XCTAssertTrue(hideSpent.isSelected, "tapping the menu item turns the filter on")

        // Restore, so the live-persisted setting doesn't leak into other tests.
        hideSpent.tap()
        optionsMenu.tap()
        XCTAssertTrue(hideSpent.waitForExistence(timeout: 5))
        XCTAssertFalse(hideSpent.isSelected, "tapping again turns the filter back off")
    }
}
