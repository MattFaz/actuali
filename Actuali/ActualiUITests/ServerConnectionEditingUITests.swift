import XCTest

final class ServerConnectionEditingUITests: XCTestCase {

    @MainActor
    func testConnectedServerURLsCanBeEditedWithoutDisconnecting() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-connectedServerSettings", "-initialTab", "4", "-currentBudgetId", "",
        ]
        app.launch()

        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Connected"].exists)
        edit.tap()

        let fallback = app.textFields["Fallback server URL (optional)"]
        XCTAssertTrue(fallback.waitForExistence(timeout: 5))
        fallback.tap()
        fallback.typeText("fallback.example.com")

        app.buttons["Save"].tap()

        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        let savedFallback = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "https://fallback.example.com")
        ).firstMatch
        XCTAssertTrue(savedFallback.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Connected"].exists)
        XCTAssertTrue(app.buttons["Disconnect"].exists)
    }
}
