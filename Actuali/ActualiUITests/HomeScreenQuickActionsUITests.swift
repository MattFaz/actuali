import XCTest

final class HomeScreenQuickActionsUITests: XCTestCase {
    @MainActor
    func testWarmShortcutOpensAddTransaction() throws {
        try assertShortcutOpensAddTransaction(coldLaunch: false)
    }

    @MainActor
    func testColdShortcutOverridesStartPage() throws {
        try assertShortcutOpensAddTransaction(coldLaunch: true)
    }

    @MainActor
    private func assertShortcutOpensAddTransaction(coldLaunch: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "0"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Accounts"].waitForExistence(timeout: 15))

        // Home Screen launches don't inherit XCUITest's launch arguments.
        // Persist a different Start Page so missing cold-launch routing
        // cannot pass just because Add was already the default.
        let originalStartPage = coldLaunch ? try setStartPage("Budget", in: app) : nil
        defer {
            if let originalStartPage {
                XCTAssertNoThrow(try setStartPage(originalStartPage, in: app))
            }
        }

        app.tabBars.buttons["Accounts"].tap()
        XCTAssertTrue(app.tabBars.buttons["Accounts"].isSelected)
        XCUIDevice.shared.press(.home)
        if coldLaunch {
            app.terminate()
            XCTAssertEqual(app.state, .notRunning)
        }

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var visibleIcon: XCUIElement?
        // SpringBoard also exposes off-screen icons with zero-sized frames.
        for _ in 0..<4 {
            visibleIcon = springboard.icons.matching(identifier: "Actuali")
                .allElementsBoundByIndex.first { $0.isHittable }
            if visibleIcon != nil {
                break
            }
            springboard.swipeLeft()
        }
        guard let icon = visibleIcon else {
            XCTFail("Actuali Home Screen icon not reachable: \(springboard.debugDescription)")
            return
        }
        icon.press(forDuration: 1.2)
        let shortcut = springboard.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Add Transaction")
        ).firstMatch
        XCTAssertTrue(shortcut.waitForExistence(timeout: 5), "Home Screen quick action missing")
        shortcut.tap()

        XCTAssertTrue(app.buttons["addTransaction.payee"].waitForExistence(timeout: 15),
                      "Quick action did not open the transaction form")
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.tabBars.buttons["Add"].isSelected)
    }

    @MainActor
    private func setStartPage(_ page: String, in app: XCUIApplication) throws -> String {
        if app.keyboards.firstMatch.exists {
            app.buttons["Done"].tap()
        }
        app.tabBars.buttons["More"].tap()
        if !app.navigationBars["Display"].exists {
            let display = app.buttons["Display"]
            XCTAssertTrue(display.waitForExistence(timeout: 5))
            display.tap()
        }
        let picker = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Start Page'")
        ).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let original = try XCTUnwrap(["Accounts", "Budget", "Add Transaction", "Reports"].first {
            picker.label.contains($0)
        })
        picker.tap()
        // The tab bar has buttons with the same labels as these menu items.
        let option = try XCTUnwrap(app.buttons.matching(identifier: page)
            .allElementsBoundByIndex.first { $0.isHittable })
        option.tap()
        XCTAssertTrue(picker.label.contains(page))
        return original
    }
}
