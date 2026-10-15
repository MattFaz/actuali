import XCTest

/// The Accounts toolbar eye flips the same Hide Balances preference as
/// Settings → Privacy.
final class HideBalancesToggleUITests: XCTestCase {
    @MainActor
    func testToolbarToggleMasksAndRevealsBalances() {
        let app = XCUIApplication()
        // Start unmasked whatever an earlier run left persisted.
        app.launchArguments = ["-loadDemoData", "-hideBalances", "NO"]
        app.launch()

        let accountsTab = app.tabBars.buttons["Accounts"]
        XCTAssertTrue(accountsTab.waitForExistence(timeout: 10))
        accountsTab.tap()
        let group = app.buttons["account.group.on-budget"]
        XCTAssertTrue(group.waitForExistence(timeout: 10))
        XCTAssertFalse(group.label.contains("••••"))

        let toggle = app.buttons["accounts.hideBalances"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        expectation(for: NSPredicate(format: "label CONTAINS '••••'"), evaluatedWith: group)
        waitForExpectations(timeout: 10)

        toggle.tap()
        expectation(for: NSPredicate(format: "NOT (label CONTAINS '••••')"), evaluatedWith: group)
        waitForExpectations(timeout: 10)
    }
}
