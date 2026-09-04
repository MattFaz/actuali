import XCTest

final class SettingsNavigationUITests: XCTestCase {
    //Due to FinanceKit requiring an Entitlement request from Apple
    //this check was added to prevent local development from crashing
    //when the active development team has not applied for that entitlement
    private func appDeclaresFinanceKitEntitlement() throws -> Bool {
        let url = try XCTUnwrap(
            Bundle(for: SettingsNavigationUITests.self).url(
                forResource: "Actuali",
                withExtension: "entitlements"
            )
        )
        let data = try Data(contentsOf: url)
        let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
        let entitlements = try XCTUnwrap(propertyList as? [String: Any])

        switch entitlements["com.apple.developer.financekit"] {
        case let enabled as Bool:
            return enabled
        case let values as [String]:
            return values.contains("financial-data")
        default:
            return false
        }
    }

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

        let hasFinanceKitEntitlement = try appDeclaresFinanceKitEntitlement()

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
            if destination == "Bank Sync (SimpleFIN & Wallet)", !hasFinanceKitEntitlement {
                continue
            }

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
}
