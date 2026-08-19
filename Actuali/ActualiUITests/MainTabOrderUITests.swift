import XCTest

/// Locks in the visual order of the bottom tab bar: Budget before Accounts.
/// Other tests select tabs by label, so they pass regardless of position —
/// this is the only coverage that would catch the order being swapped back.
final class MainTabOrderUITests: XCTestCase {

    @MainActor
    func testBudgetTabPrecedesAccountsTab() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()

        let budgetTab = app.tabBars.buttons["Budget"]
        let accountsTab = app.tabBars.buttons["Accounts"]
        XCTAssertTrue(budgetTab.waitForExistence(timeout: 10), "Budget tab not found")
        XCTAssertTrue(accountsTab.waitForExistence(timeout: 10), "Accounts tab not found")

        XCTAssertLessThan(budgetTab.frame.minX, accountsTab.frame.minX,
                          "Budget tab should appear before Accounts in the tab bar")
    }
}
