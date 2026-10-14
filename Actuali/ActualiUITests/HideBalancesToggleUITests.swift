import XCTest

/// The toolbar eye flips the same Hide Balances preference as Settings →
/// Privacy, from both the Accounts and Budget tabs.
final class HideBalancesToggleUITests: XCTestCase {
    @MainActor
    func testToolbarToggleMasksAndRevealsBalances() {
        let app = XCUIApplication()
        // Start unmasked whatever an earlier run left persisted.
        app.launchArguments = ["-loadDemoData", "-hideBalances", "NO",
                               "-budgetDisplayStyle", "clean"]
        app.launch()

        let masked = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "\u{2022}\u{2022}\u{2022}\u{2022}"))
            .firstMatch
        let toggle = app.descendants(matching: .any)
            .matching(identifier: "toolbar.hideBalances")
            .firstMatch

        app.tabBars.buttons["Accounts"].tap()
        XCTAssertTrue(app.buttons["account.group.on-budget"].waitForExistence(timeout: 10))
        XCTAssertFalse(masked.exists)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        XCTAssertTrue(masked.waitForExistence(timeout: 5),
                      "Accounts toggle did not mask balances")

        app.tabBars.buttons["Budget"].tap()
        XCTAssertTrue(app.buttons["Details for Groceries"].waitForExistence(timeout: 10))
        XCTAssertTrue(masked.waitForExistence(timeout: 5))
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: masked)
        waitForExpectations(timeout: 5)
    }
}
