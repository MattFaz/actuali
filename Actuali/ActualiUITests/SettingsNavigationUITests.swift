import XCTest

final class SettingsNavigationUITests: XCTestCase {
    @MainActor
    func testHubOpensEverySettingsDestination() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "4"]
        app.launch()

        for destination in [
            "Connection & Data",
            "Budget View",
            "Transactions & Automation",
            "Display",
            "Privacy",
            "About"
        ] {
            let row = app.buttons[destination]
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(destination) row not found")
            row.tap()

            let navigationBar = app.navigationBars[destination]
            XCTAssertTrue(
                navigationBar.waitForExistence(timeout: 5),
                "\(destination) screen did not open"
            )
            navigationBar.buttons.element(boundBy: 0).tap()
        }
    }
}
