import XCTest

/// The preference is exposed directly below Hide Balances and updates money
/// labels throughout the live app without changing the underlying cent values.
final class HideDecimalPlacesUITests: XCTestCase {

    @MainActor
    func testPreferenceRemovesFractionalDigitsFromBudgetAmounts() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()

        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 15))
        settingsTab.tap()

        let toggle = app.switches["Hide Decimal Places"]
        var swipesLeft = 8
        while !toggle.exists && swipesLeft > 0 {
            app.swipeUp()
            swipesLeft -= 1
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "Hide Decimal Places toggle not found in Preferences")
        if toggle.value as? String == "1" { toggle.tap() }
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "1")

        let hideBalances = app.switches["Hide Balances"]
        XCTAssertTrue(hideBalances.exists)
        if hideBalances.value as? String == "1" { hideBalances.tap() }

        app.tabBars.buttons["Budget"].tap()
        XCTAssertTrue(app.buttons["Details for Groceries"].waitForExistence(timeout: 10))

        let decimalAmount = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES '.*[0-9][.][0-9]{2}.*'"))
        XCTAssertEqual(decimalAmount.count, 0,
                       "Budget still exposed a two-digit fractional amount")
    }
}
