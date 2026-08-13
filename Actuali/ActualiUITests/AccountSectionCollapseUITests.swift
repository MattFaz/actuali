import XCTest

/// Collapsible account sections (GH #208): section headers collapse and
/// re-expand their accounts independently, keep their totals visible while
/// collapsed, and the collapsed state survives an app relaunch — the same
/// contract the budget tab's group collapse honors.
final class AccountSectionCollapseUITests: XCTestCase {

    @MainActor
    private func launchOnAccountsTab() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()

        app.tabBars.buttons["Accounts"].tap()
        return app
    }

    @MainActor
    func testSectionsCollapseAndExpandIndependently() throws {
        let app = launchOnAccountsTab()

        // Demo data seeds Chase Checking on budget and Vanguard Brokerage off.
        let chase = app.staticTexts["Chase Checking"].firstMatch
        XCTAssertTrue(chase.waitForExistence(timeout: 10),
                      "demo data should show the on-budget accounts")
        let vanguard = app.staticTexts["Vanguard Brokerage"].firstMatch
        XCTAssertTrue(vanguard.waitForExistence(timeout: 10),
                      "demo data should show the off-budget accounts")

        let expandedHeader = app.buttons["On Budget, expanded"]
        XCTAssertTrue(expandedHeader.waitForExistence(timeout: 10))
        expandedHeader.tap()

        // Collapsing hides the section's accounts but not its neighbors, and
        // the header keeps announcing the section total.
        let collapsedHeader = app.buttons["On Budget, collapsed"]
        XCTAssertTrue(collapsedHeader.waitForExistence(timeout: 10))
        XCTAssertFalse(chase.exists,
                       "collapsing On Budget should hide its accounts")
        XCTAssertTrue(vanguard.exists,
                      "collapsing On Budget should leave Off Budget alone")
        XCTAssertNotEqual(collapsedHeader.label, "On Budget, collapsed",
                          "the collapsed header should still carry the section total")

        collapsedHeader.tap()
        XCTAssertTrue(chase.waitForExistence(timeout: 10),
                      "expanding On Budget should restore its accounts")
    }

    @MainActor
    func testCollapsedSectionSurvivesRelaunch() throws {
        var app = launchOnAccountsTab()

        let chase = app.staticTexts["Chase Checking"].firstMatch
        XCTAssertTrue(chase.waitForExistence(timeout: 10))

        let expandedHeader = app.buttons["On Budget, expanded"]
        XCTAssertTrue(expandedHeader.waitForExistence(timeout: 10))
        expandedHeader.tap()
        XCTAssertTrue(app.buttons["On Budget, collapsed"].waitForExistence(timeout: 10))

        app.terminate()
        app = launchOnAccountsTab()

        let collapsedHeader = app.buttons["On Budget, collapsed"]
        XCTAssertTrue(collapsedHeader.waitForExistence(timeout: 10),
                      "the collapsed state should survive a relaunch")
        XCTAssertFalse(app.staticTexts["Chase Checking"].firstMatch.exists,
                       "the section should come back collapsed")

        // Expand again so the persisted state can't bleed into other tests.
        collapsedHeader.tap()
        XCTAssertTrue(app.staticTexts["Chase Checking"].firstMatch.waitForExistence(timeout: 10))
    }
}
