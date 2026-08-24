import XCTest

/// The preference is exposed directly below Hide Balances and updates money
/// labels throughout the live app without changing the underlying cent values.
final class HideDecimalPlacesUITests: XCTestCase {

    /// SwiftUI toggle rows may expose a nested switch whose control must be
    /// tapped directly on some iOS versions.
    @MainActor
    private func tapSwitch(_ toggle: XCUIElement) {
        let control = toggle.switches.firstMatch
        (control.exists ? control : toggle).tap()
    }

    @MainActor
    func testPreferenceRemovesFractionalDigitsFromBudgetAmounts() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "4"]
        app.launch()

        let privacy = app.buttons["Privacy"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 15))
        privacy.tap()

        let toggle = app.switches["Hide Decimal Places"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "Hide Decimal Places toggle not found in Privacy")
        let decimalPlacesWasHidden = toggle.value as? String == "1"

        let hideBalances = app.switches["Hide Balances"]
        XCTAssertTrue(hideBalances.exists)
        let balancesWereHidden = hideBalances.value as? String == "1"

        defer {
            app.tabBars.buttons["Settings"].tap()
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            if (toggle.value as? String == "1") != decimalPlacesWasHidden {
                tapSwitch(toggle)
            }
            if (hideBalances.value as? String == "1") != balancesWereHidden {
                tapSwitch(hideBalances)
            }
        }

        if !decimalPlacesWasHidden { tapSwitch(toggle) }
        let enabled = NSPredicate(format: "value == '1'")
        expectation(for: enabled, evaluatedWith: toggle)
        waitForExpectations(timeout: 3)

        if balancesWereHidden { tapSwitch(hideBalances) }

        app.tabBars.buttons["Budget"].tap()
        XCTAssertTrue(app.buttons["Details for Groceries"].waitForExistence(timeout: 10))

        let decimalAmount = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES '.*[0-9][.][0-9]{2}.*'"))
        XCTAssertEqual(decimalAmount.count, 0,
                       "Budget still exposed a two-digit fractional amount")
    }
}
