import XCTest

final class CategoryFundingAutomationUITests: XCTestCase {
    @MainActor
    func testCategoryFundingSettingsCanBeConfigured() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "4"]
        app.launch()

        let automation = app.buttons["Category Funding Settings"]
        XCTAssertTrue(automation.waitForExistence(timeout: 10), "Category Funding Settings row not found")
        automation.tap()

        XCTAssertTrue(app.navigationBars["Category Funding"].waitForExistence(timeout: 5), "Category Funding screen did not open")

        let accountPicker = app.buttons["Account"]
        XCTAssertTrue(accountPicker.waitForExistence(timeout: 5), "Account picker not found")
        accountPicker.tap()

        let checking = app.buttons["Chase Checking"]
        XCTAssertTrue(checking.waitForExistence(timeout: 5), "Demo account not available in picker")
        checking.tap()

        let enable = app.switches["Enable Automation"]
        XCTAssertTrue(enable.waitForExistence(timeout: 5), "Enable Automation toggle not found")
        XCTAssertTrue(enable.isEnabled, "Enable Automation should be enabled after choosing an account")
    }
}
