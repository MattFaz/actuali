import XCTest

/// Account-group editing is gated on the server supporting account_groups
/// (>= 26.9.0). Like payee locations, the cached answer lives in UserDefaults
/// under `accountGroupWritesEnabled_<serverURL>`, and demo data leaves
/// serverURL empty, so a `-key value` launch argument flips the gate.
final class AccountGroupsGateUITests: XCTestCase {
    @MainActor
    private func launch(groupWrites: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-serverURL", "",
                               "-accountGroupWritesEnabled_", groupWrites ? "1" : "0"]
        app.launch()
        app.tabBars.buttons["Accounts"].tap()
        XCTAssertTrue(app.staticTexts["Chase Checking"].firstMatch.waitForExistence(timeout: 10))
        return app
    }

    /// The options Menu's accessibility label does not survive toolbar
    /// rendering on every OS, so fall back to the system overflow names.
    @MainActor
    private func openOptionsMenu(_ app: XCUIApplication) {
        let bar = app.navigationBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        let button = ["Accounts options", "More", "OverflowBarButtonItem", "ellipsis.circle"]
            .map { bar.buttons[$0].firstMatch }
            .first(where: \.exists)
        guard let button else {
            return XCTFail("options menu not found in: \(bar.buttons.debugDescription)")
        }
        button.tap()
    }

    @MainActor
    private func assertGroupControls(groupWrites: Bool) {
        var app = launch(groupWrites: groupWrites)
        openOptionsMenu(app)
        XCTAssertTrue(app.buttons["Credit Cards"].waitForExistence(timeout: 5), "options menu did not open")
        // The demo now has seeded groups, so this entry remains visible even
        // when editing is gated off; it explains the server-version requirement.
        XCTAssertTrue(app.buttons["Manage Account Groups"].exists)

        // Relaunch rather than dismiss the menu, which has no stable target.
        app.terminate()
        app = launch(groupWrites: groupWrites)
        app.staticTexts["Chase Checking"].firstMatch.press(forDuration: 1.2)
        XCTAssertEqual(app.buttons["Set Account Group"].waitForExistence(timeout: 3), groupWrites)
    }

    @MainActor
    func testDemoCanReorderGroupsFromAccountGroupsSheetWithoutServerSupport() {
        let app = launch(groupWrites: false)
        openOptionsMenu(app)
        let manageGroups = app.buttons["Manage Account Groups"]
        XCTAssertTrue(manageGroups.waitForExistence(timeout: 5))
        manageGroups.tap()

        XCTAssertTrue(app.buttons["accountGroups.edit"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Account groups require Actual Server 26.9.0 or later."].exists)
    }

    @MainActor
    func testGroupAssignmentControlHiddenWhenServerLacksSupport() {
        assertGroupControls(groupWrites: false)
    }

    @MainActor
    func testGroupAssignmentControlShownWhenServerSupportsGroups() {
        assertGroupControls(groupWrites: true)
    }
}
