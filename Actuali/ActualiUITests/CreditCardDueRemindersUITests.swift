import XCTest

final class CreditCardDueRemindersUITests: XCTestCase {
    @MainActor
    func testEnablingRemindersSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "4"]
        app.launch()
        app.tabBars.buttons["More"].tap()

        let automation = app.buttons["Transactions & Automation"]
        XCTAssertTrue(automation.waitForExistence(timeout: 10))
        automation.tap()

        let toggle = app.switches["Credit Card Due Reminders"]
        for _ in 0..<5 where !toggle.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(toggle.isHittable)
        if toggle.value as? String == "1" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()

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
        for _ in 0..<5 where !toggle.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }
}
