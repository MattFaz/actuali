import XCTest

/// GH #755: off-budget alerts can be muted without losing on-budget ones.
final class OffBudgetNotificationsUITests: XCTestCase {
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
    private func setSwitch(_ toggle: XCUIElement, on: Bool) {
        let target = on ? "1" : "0"
        if toggle.value as? String != target {
            tapControl(toggle) { toggle.value as? String == target }
        }
    }

    @MainActor
    func testOffBudgetToggleFollowsAlertsAndPersists() {
        let app = XCUIApplication()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        let alerts = app.switches["notifications.newTransactionAlerts"]
        let offBudget = app.switches["notifications.includeOffBudget"]
        addTeardownBlock { @MainActor in
            // Shared simulator defaults must not leak into later tests.
            if allow.exists {
                allow.tap()
            }
            if app.state != .notRunning {
                app.terminate()
            }
            app.launchArguments = ["-initialTab", "4"]
            app.launch()
            guard self.openNotifications(in: app), alerts.waitForExistence(timeout: 5) else { return }
            if offBudget.exists {
                self.setSwitch(offBudget, on: true)
            }
            self.setSwitch(alerts, on: false)
        }
        app.launchArguments = ["-loadDemoData", "-initialTab", "4"]
        app.launch()
        XCTAssertTrue(openNotifications(in: app), "Notifications settings should open from More")
        XCTAssertTrue(alerts.waitForExistence(timeout: 5))

        setSwitch(alerts, on: false)
        XCTAssertFalse(offBudget.exists, "Off-budget toggle only applies while alerts are on")

        setSwitch(alerts, on: true)
        if allow.waitForExistence(timeout: 3) {
            allow.tap()
        }
        XCTAssertTrue(offBudget.waitForExistence(timeout: 5))
        XCTAssertEqual(offBudget.value as? String, "1", "Off-budget alerts default on")
        setSwitch(offBudget, on: false)

        app.terminate()
        app.launchArguments = ["-initialTab", "4"]
        app.launch()
        XCTAssertTrue(openNotifications(in: app), "Notifications settings should reopen after relaunch")
        XCTAssertTrue(offBudget.waitForExistence(timeout: 5))
        XCTAssertEqual(offBudget.value as? String, "0")
    }
}
