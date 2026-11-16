import CoreLocation
import XCTest

/// Home location (GH #845): a new transaction entered near Home starts with
/// Save Location off; one entered elsewhere keeps the default on.
final class HomeLocationUITests: XCTestCase {
    private let launchArguments = [
        "-loadDemoData", "-serverURL", "", "-payeeLocationWritesEnabled_", "1",
    ]

    /// Scroll a SwiftUI Form until an off-screen row is created.
    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        var swipes = 0
        while !element.exists, swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
    }

    @MainActor
    private func saveLocationValue(at coordinate: CLLocationCoordinate2D) -> String? {
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(
            latitude: coordinate.latitude, longitude: coordinate.longitude
        ))
        let app = XCUIApplication()
        app.launchArguments = launchArguments + ["-initialTab", "2"]
        app.launch()
        let toggle = app.switches["addTransaction.saveLocation"]
        scrollTo(toggle, in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Save Location toggle not shown")
        // The at-home check resolves after the form appears.
        sleep(3)
        return toggle.value as? String
    }

    @MainActor
    func testSaveLocationStartsOffNearHome() {
        let home = CLLocationCoordinate2D(latitude: -33.8568, longitude: 151.2153)
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(
            latitude: home.latitude, longitude: home.longitude
        ))

        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .location)
        app.launchArguments = launchArguments + ["-initialTab", "4"]
        app.launch()

        let transactionSettings = app.buttons["Transactions & Automation"]
        XCTAssertTrue(transactionSettings.waitForExistence(timeout: 5))
        transactionSettings.tap()

        // A previous run may have left Home set; start from a cleared state.
        let clear = app.buttons["transactionAutomation.clearHomeLocation"]
        let set = app.buttons["transactionAutomation.setHomeLocation"]
        scrollTo(set, in: app)
        if clear.exists {
            clear.tap()
        }
        XCTAssertTrue(set.waitForExistence(timeout: 5), "Set Home button not shown")
        set.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 5) {
            allow.tap()
        }
        XCTAssertTrue(clear.waitForExistence(timeout: 10), "Home was not set from the current location")
        app.terminate()

        XCTAssertEqual(saveLocationValue(at: home), "0", "Save Location should start off at Home")

        // ~1.1 km north of Home.
        let away = CLLocationCoordinate2D(latitude: -33.8468, longitude: 151.2153)
        XCTAssertEqual(saveLocationValue(at: away), "1", "Save Location should stay on away from Home")
    }
}
