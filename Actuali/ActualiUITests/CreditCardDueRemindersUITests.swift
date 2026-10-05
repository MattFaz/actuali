import XCTest

final class CreditCardDueRemindersUITests: XCTestCase {
    @MainActor
    func testEnablingRemindersSurvivesRelaunch() {
        let app = XCUIApplication()
        addTeardownBlock { @MainActor in
            // Shared simulator defaults must not leave reminders enabled for
            // later tests, even when this test fails before its last assertion.
            let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
            if allow.exists {
                allow.tap()
            }
            if app.state != .runningForeground {
                app.launchArguments = ["-initialTab", "4"]
                app.launch()
            }
            app.tabBars.buttons["More"].tap()
            let automation = app.buttons["Transactions & Automation"]
            if automation.waitForExistence(timeout: 5) {
                automation.tap()
            }
            let toggle = app.switches["Credit Card Due Reminders"]
            guard toggle.waitForExistence(timeout: 5) else { return }
            self.scrollUntilHittable(toggle, in: app, maxSwipes: 5)
            if toggle.value as? String == "1" {
                self.tapControl(toggle) { toggle.value as? String == "0" }
            }
        }
        app.launchArguments = ["-loadDemoData", "-initialTab", "4"]
        app.launch()
        app.tabBars.buttons["More"].tap()

        let automation = app.buttons["Transactions & Automation"]
        XCTAssertTrue(automation.waitForExistence(timeout: 10))
        automation.tap()

        let toggle = app.switches["Credit Card Due Reminders"]
        scrollUntilHittable(toggle, in: app, maxSwipes: 5)
        XCTAssertTrue(toggle.isHittable)
        if toggle.value as? String == "1" {
            tapControl(toggle) { toggle.value as? String == "0" }
        }
        tapControl(toggle) { toggle.value as? String == "1" }

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) {
            allow.tap()
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertEqual(toggle.value as? String, "1")

        app.terminate()
        app.launchArguments = ["-initialTab", "4"]
        app.launch()
        app.tabBars.buttons["More"].tap()
        XCTAssertTrue(automation.waitForExistence(timeout: 10), "App must launch with reminders enabled")
        automation.tap()
        scrollUntilHittable(toggle, in: app, maxSwipes: 5)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
    }
}
