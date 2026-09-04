import XCTest

final class SettingsNavigationUITests: XCTestCase {
    @MainActor
    private func assertExpectedContent(for destination: String, in app: XCUIApplication) {
        let content: XCUIElement
        switch destination {
        case "Connection & Data":
            content = app.textFields["Server URL"]
        case "Budget View":
            content = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH 'View Style'")
            ).firstMatch
        case "Transactions & Automation":
            content = app.switches["Conventional Amount Entry"]
        case "Display":
            content = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH 'Currency'")
            ).firstMatch
        case "Privacy":
            content = app.switches["Hide Balances"]
        case "Scheduled Transactions":
            content = app.searchFields["Search schedules"]
        case "Rules":
            // The demo budget does not include a rules table, so RulesListView
            // shows its unavailable placeholder instead of the Add Rule button.
            content = app.staticTexts["Rules Unavailable"]
        case "Bank Sync (SimpleFIN & Wallet)":
            content = app.textFields["Setup token"]
        case "About":
            content = app.staticTexts["Version"]
        default:
            XCTFail("No representative content assertion for \(destination)")
            return
        }

        XCTAssertTrue(
            content.waitForExistence(timeout: 5),
            "\(destination) opened without its expected content"
        )
    }

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
            "Scheduled Transactions",
            "Rules",
            "Bank Sync (SimpleFIN & Wallet)",
            "About"
        ] {
            let row = app.buttons[destination]
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(destination) row not found")
            row.tap()

            let navigationBar = app.navigationBars[
                destination == "Bank Sync (SimpleFIN & Wallet)" ? "Bank Sync" : destination
            ]
            XCTAssertTrue(
                navigationBar.waitForExistence(timeout: 5),
                "\(destination) screen did not open"
            )
            assertExpectedContent(for: destination, in: app)
            navigationBar.buttons.element(boundBy: 0).tap()
        }
    }

    @MainActor
    func testBudgetSelectionPickerShowsOtherBudgetsAndDismissesOnSelection() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-connectedServerSettings",
            "-budgetSelectionFixture",
            "-initialTab",
            "4"
        ]
        app.launch()

        let row = app.buttons["Connection & Data"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        let selected = app.buttons["budget-selection-selected"]
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Other Budget"].exists)
        XCTAssertFalse(app.buttons["Encrypted Budget"].exists)

        selected.tap()

        let other = app.buttons["Other Budget"]
        XCTAssertTrue(other.waitForExistence(timeout: 5))

        let encrypted = app.buttons["Encrypted Budget"]
        XCTAssertTrue(encrypted.waitForExistence(timeout: 5))
        XCTAssertTrue(encrypted.images.firstMatch.waitForExistence(timeout: 5))

        other.tap()

        XCTAssertFalse(app.buttons["Encrypted Budget"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["budget-selection-selected"].exists)
    }

    @MainActor
    func testBudgetSelectionLongPressShowsManagementActions() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-connectedServerSettings",
            "-budgetSelectionFixture",
            "-initialTab",
            "4"
        ]
        app.launch()

        let row = app.buttons["Connection & Data"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        let selected = app.buttons["budget-selection-selected"]
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        selected.press(forDuration: 1.0)

        XCTAssertTrue(app.buttons["Remove from This Device"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Delete from Server…"].waitForExistence(timeout: 5))
    }
}
