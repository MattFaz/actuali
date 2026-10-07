import XCTest

/// Collapsible account sections (GH #208): section headers collapse and
/// re-expand their accounts independently, keep their totals visible while
/// collapsed, and the collapsed state survives an app relaunch — the same
/// contract the budget tab's group collapse honors.
final class AccountSectionCollapseUITests: XCTestCase {
    @MainActor
    private func launchOnAccountsTab(expandingSections: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()

        app.tabBars.buttons["Accounts"].tap()
        // Expansion persists across runs; normalize only the initial launch.
        if expandingSections {
            for identifier in ["on-budget", "off-budget"] {
                let header = app.buttons["account.group.\(identifier)"]
                XCTAssertTrue(header.waitForExistence(timeout: 10))
                if header.label.contains("collapsed") {
                    header.tap()
                }
            }
        }
        return app
    }

    @MainActor
    func testSectionsCollapseAndExpandIndependently() {
        let app = launchOnAccountsTab()

        // Demo data seeds Chase Checking on budget and Vanguard Brokerage off.
        let chase = app.staticTexts["Chase Checking"].firstMatch
        XCTAssertTrue(chase.waitForExistence(timeout: 10),
                      "demo data should show the on-budget accounts")
        let vanguard = app.staticTexts["Vanguard Brokerage"].firstMatch
        XCTAssertTrue(vanguard.waitForExistence(timeout: 10),
                      "demo data should show the off-budget accounts")

        let expandedHeader = app.buttons["account.group.on-budget"]
        XCTAssertTrue(expandedHeader.waitForExistence(timeout: 10))
        expandedHeader.tap()

        // Collapsing hides the section's accounts but not its neighbors, and
        // the header keeps announcing the section total.
        let collapsedHeader = app.buttons["account.group.on-budget"]
        XCTAssertTrue(collapsedHeader.waitForExistence(timeout: 10))
        XCTAssertFalse(chase.exists,
                       "collapsing On Budget should hide its accounts")
        XCTAssertTrue(vanguard.exists,
                      "collapsing On Budget should leave Off Budget alone")
        XCTAssertGreaterThanOrEqual(
            collapsedHeader.label.components(separatedBy: ", ").count,
            3,
            "the collapsed header should still carry the section total"
        )

        collapsedHeader.tap()
        XCTAssertTrue(chase.waitForExistence(timeout: 10),
                      "expanding On Budget should restore its accounts")
    }

    @MainActor
    func testCollapsedSectionSurvivesRelaunch() {
        var app = launchOnAccountsTab()

        let chase = app.staticTexts["Chase Checking"].firstMatch
        XCTAssertTrue(chase.waitForExistence(timeout: 10))

        let expandedHeader = app.buttons["account.group.on-budget"]
        XCTAssertTrue(expandedHeader.waitForExistence(timeout: 10))
        expandedHeader.tap()
        XCTAssertTrue(app.buttons["account.group.on-budget"].waitForExistence(timeout: 10))

        app.terminate()
        app = launchOnAccountsTab(expandingSections: false)

        let collapsedHeader = app.buttons["account.group.on-budget"]
        XCTAssertTrue(collapsedHeader.waitForExistence(timeout: 10),
                      "the collapsed state should survive a relaunch")
        XCTAssertFalse(app.staticTexts["Chase Checking"].firstMatch.exists,
                       "the section should come back collapsed")

        // Expand again so the persisted state can't bleed into other tests.
        collapsedHeader.tap()
        XCTAssertTrue(app.staticTexts["Chase Checking"].firstMatch.waitForExistence(timeout: 10))
    }
}
