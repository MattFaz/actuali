import XCTest

final class CategoryFundingAutomationUITests: XCTestCase {
    @MainActor
    func testCategoryFundingSettingsCanBeOpened() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "4"]
        app.launch()

        let settings = app.buttons["Transactions & Automation"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let categoryFunding = app.buttons["Category Funding Settings"]
        XCTAssertTrue(categoryFunding.waitForExistence(timeout: 5))
        categoryFunding.tap()
        XCTAssertTrue(app.navigationBars["Category Funding"].waitForExistence(timeout: 5))
    }
}