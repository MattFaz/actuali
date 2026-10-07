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
            // The demo budget ships Rent and Netflix schedules. Assert on the
            // row rather than the "Search schedules" field: with a non-empty
            // list iOS 26 collapses the search bar into a nav-bar glyph, so
            // no SearchField element exists to match.
            content = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH 'Rent'")
            ).firstMatch
        case "Rules":
            // The demo budget ships a rules table with rules in it, so
            // RulesListView shows the list with its Add Rule toolbar button
            // instead of the no-rules-table placeholder.
            content = app.buttons["Add Rule"]
        case "Bank Sync (SimpleFIN & Wallet)":
            content = app.textFields["Setup token"]
        case "History":
            content = app.staticTexts["No History Yet"]
        case "Support & Diagnostic":
            content = app.descendants(matching: .any)["support.discord"]
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
    func testHubOpensEverySettingsDestination() {
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
            "History",
            "Support & Diagnostic",
        ] {
            let row = rowOnHub(destination, in: app)
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(destination) row not found")
            row.tap()

            let navigationBar = app.navigationBars[
                destination == "Bank Sync (SimpleFIN & Wallet)"
                    ? "Bank Sync"
                    : destination == "Support & Diagnostic"
                    ? "Support"
                    : destination
            ]
            XCTAssertTrue(
                navigationBar.waitForExistence(timeout: 5),
                "\(destination) screen did not open"
            )
            assertExpectedContent(for: destination, in: app)
            navigationBar.buttons.element(boundBy: 0).tap()
            if destination == "Support & Diagnostic" {
                // GH #533: Privacy Policy and Version moved into the Information
                // section beside Support; assert them once back on the hub, where
                // that section is on screen, so a regression can't silently drop
                // either row.
                XCTAssertTrue(
                    app.descendants(matching: .any)["settings.privacyPolicy"].waitForExistence(timeout: 5),
                    "Privacy Policy row missing from the Information section"
                )
                XCTAssertTrue(
                    app.staticTexts["Version"].waitForExistence(timeout: 5),
                    "Version row missing from the Information section"
                )
            }
        }
    }

    /// The Shortcuts section (GH #528) pushes the bottom rows below the
    /// fold, and a SwiftUI Form doesn't materialize off-screen rows — swipe
    /// until the row exists before asserting on it.
    @MainActor
    private func rowOnHub(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons.matching(
            NSPredicate(format: "label == %@", title)
        ).firstMatch
        let link = app.links.matching(
            NSPredicate(format: "label == %@", title)
        ).firstMatch
        var swipes = 0
        while !button.exists && !link.exists && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        return button.exists ? button : link
    }

    @MainActor
    func testSupportShowsDiagnosticReportWithCopyAndShare() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "4"]
        app.launch()

        let support = rowOnHub("Support & Diagnostic", in: app)
        XCTAssertTrue(support.waitForExistence(timeout: 5))
        support.tap()

        let diagnosticReport = app.buttons["support.diagnosticReport"]
        XCTAssertTrue(diagnosticReport.waitForExistence(timeout: 5))
        diagnosticReport.tap()

        XCTAssertTrue(app.navigationBars["Diagnostic Report"].waitForExistence(timeout: 5))

        let copyButton = app.buttons["diagnosticReport.copy"]
        XCTAssertTrue(copyButton.waitForExistence(timeout: 5))
        copyButton.tap()
        XCTAssertEqual(copyButton.label, "Diagnostic Report Copied")

        XCTAssertTrue(app.buttons["diagnosticReport.share"].waitForExistence(timeout: 5))
        let report = app.staticTexts["diagnosticReport.text"]
        XCTAssertTrue(report.waitForExistence(timeout: 5))
        let capturedText = report.label
        // The generated timestamp used to change each second, replacing the
        // selectable text and making the copied/shared report drift.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertEqual(report.label, capturedText)
    }

    @MainActor
    func testBudgetSelectionPickerShowsOtherBudgetsAndDismissesOnSelection() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-connectedServerSettings",
            "-budgetSelectionFixture",
            "-initialTab",
            "4",
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

        XCTAssertFalse(app.buttons["Other Budget"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["Encrypted Budget"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["budget-selection-selected"].exists)
    }

    @MainActor
    func testBudgetSelectionLongPressShowsManagementActions() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-connectedServerSettings",
            "-budgetSelectionFixture",
            "-initialTab",
            "4",
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
