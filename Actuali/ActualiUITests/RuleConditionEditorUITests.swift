import XCTest

final class RuleConditionEditorUITests: XCTestCase {
    @MainActor
    func testMultiValueLinkOpensPayeePicker() {
        let app = XCUIApplication()
        app.launchArguments = ["-showRuleConditionFixture"]
        app.launch()

        let selectedCount = app.staticTexts["Values, 0 selected"]
        XCTAssertTrue(selectedCount.waitForExistence(timeout: 5))
        selectedCount.tap()

        XCTAssertTrue(app.navigationBars["Payee"].waitForExistence(timeout: 2))
    }
}
