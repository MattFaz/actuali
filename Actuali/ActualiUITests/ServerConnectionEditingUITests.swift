import XCTest

final class ServerConnectionEditingUITests: XCTestCase {
    @MainActor
    func testConnectedServerURLsCanBeEditedWithoutDisconnecting() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-connectedServerSettings", "-initialTab", "4", "-currentBudgetId", "",
        ]
        app.launch()

        let connectionData = app.buttons["Connection & Data"]
        XCTAssertTrue(connectionData.waitForExistence(timeout: 10))
        connectionData.tap()

        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Connected"].exists)
        edit.tap()

        let fallback = app.textFields["Fallback Server URL"]
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

    /// Picking an encrypted budget from the post-connect prompt used to drop
    /// the password sheet, leaving no way to unlock the budget.
    @MainActor
    func testPostConnectPromptOpensPasswordSheetForEncryptedBudget() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-connectedServerSettings", "-budgetSelectionFixture",
            "-initialTab", "4", "-currentBudgetId", "",
        ]
        app.launch()

        let connectionData = app.buttons["Connection & Data"]
        XCTAssertTrue(connectionData.waitForExistence(timeout: 10))
        connectionData.tap()

        let encrypted = app.buttons["budgetSelectPrompt.budget.debug-encrypted-budget"]
        XCTAssertTrue(encrypted.waitForExistence(timeout: 10),
                      "connecting with no budget open should prompt for one")
        encrypted.tap()

        XCTAssertTrue(app.navigationBars["Unlock Budget"].waitForExistence(timeout: 5),
                      "an encrypted budget should ask for its password")
        XCTAssertTrue(app.secureTextFields["Encryption password"].exists)
    }
}
