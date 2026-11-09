import XCTest

final class CreditCardDueRemindersUITests: XCTestCase {
    @MainActor
    private func openNotifications(in app: XCUIApplication) -> Bool {
        let more = app.tabBars.buttons["More"]
        guard more.waitForExistence(timeout: 5) else { return false }
        more.tap()

        let notifications = app.buttons["Notifications"]
        guard notifications.waitForExistence(timeout: 10) else { return false }
        notifications.tap()
        return app.navigationBars["Notifications"].waitForExistence(timeout: 5)
    }

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
            if app.state != .notRunning {
                app.terminate()
            }
            app.launchArguments = ["-initialTab", "4"]
            app.launch()
            if allow.waitForExistence(timeout: 2) {
                allow.tap()
            }
            guard self.openNotifications(in: app) else { return }
            let toggle = app.switches["notifications.creditCardDueReminders"]
            guard toggle.waitForExistence(timeout: 5) else { return }
            self.scrollUntilHittable(toggle, in: app, maxSwipes: 5)
            if toggle.value as? String == "1" {
                self.tapControl(toggle) { toggle.value as? String == "0" }
            }
        }
        app.launchArguments = ["-loadDemoData", "-initialTab", "4"]
        app.launch()
        XCTAssertTrue(openNotifications(in: app), "Notifications settings should open from More")

        let toggle = app.switches["notifications.creditCardDueReminders"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
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
        XCTAssertTrue(openNotifications(in: app), "Notifications settings should reopen after relaunch")
        let persistedToggle = app.switches["notifications.creditCardDueReminders"]
        XCTAssertTrue(persistedToggle.waitForExistence(timeout: 5))
        scrollUntilHittable(persistedToggle, in: app, maxSwipes: 5)
        XCTAssertEqual(persistedToggle.value as? String, "1")
    }
}
