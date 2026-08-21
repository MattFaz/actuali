import XCTest

/// The Payee Locations screen (GH #147) is reachable from Settings and gated on
/// the server supporting payee_locations (>= 26.4.0), exactly like the
/// "Record Payee Locations" toggle beside it.
///
/// The gate's cached answer lives in UserDefaults under
/// `payeeLocationWritesEnabled_<serverURL>`, so a `-key value` launch argument
/// opens it without a real server. Demo data has no recorded locations, so the
/// screen lands on its empty state.
final class PayeeLocationsUITests: XCTestCase {

    /// Scroll a SwiftUI Form until an off-screen row is created.
    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        var swipes = 0
        while !element.exists && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
    }

    @MainActor
    func testScreenIsReachableFromSettingsWhenServerSupportsLocations() throws {
        let app = XCUIApplication()
        // Demo data leaves serverURL empty, so the cache key has an empty suffix.
        app.launchArguments = ["-loadDemoData", "-initialTab", "4",
                               "-payeeLocationWritesEnabled_", "1"]
        app.launch()

        let transactionSettings = app.buttons["Transactions & Automation"]
        XCTAssertTrue(transactionSettings.waitForExistence(timeout: 5))
        transactionSettings.tap()

        let row = app.buttons["Payee Locations"]
        scrollTo(row, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "Payee Locations row not found in Settings")

        row.tap()

        XCTAssertTrue(app.navigationBars["Payee Locations"].waitForExistence(timeout: 5),
                      "Payee Locations screen did not open")
        // Demo data records no locations, so the empty state is the correct landing.
        XCTAssertTrue(app.staticTexts["No Recorded Locations"].waitForExistence(timeout: 5),
                      "empty state did not appear for a budget with no recorded locations")
    }

    /// The reported problem: locations recorded in the wrong place must be
    /// removable from anywhere — one at a time, or all at once.
    @MainActor
    func testClearsOneLocationThenTheRest() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "4",
                               "-payeeLocationWritesEnabled_", "1",
                               "-seedPayeeLocations"]
        app.launch()

        let transactionSettings = app.buttons["Transactions & Automation"]
        XCTAssertTrue(transactionSettings.waitForExistence(timeout: 5))
        transactionSettings.tap()

        let row = app.buttons["Payee Locations"]
        scrollTo(row, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "Payee Locations row not found in Settings")
        row.tap()

        // The seeded payee is listed with both of its locations counted. The
        // row's accessibility label composes name and count.
        let payeeRow = app.buttons["Whole Foods, 2"]
        XCTAssertTrue(payeeRow.waitForExistence(timeout: 5),
                      "seeded payee not listed with a count of 2")
        payeeRow.tap()

        let sydney = app.staticTexts["-33.85680, 151.21530"]
        let melbourne = app.staticTexts["-37.81360, 144.96310"]
        XCTAssertTrue(sydney.waitForExistence(timeout: 5), "first coordinate not shown")
        XCTAssertTrue(melbourne.exists, "second coordinate not shown")

        // Swipe-delete the wrong one; the other survives.
        melbourne.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertTrue(melbourne.waitForNonExistence(timeout: 5),
                      "swiped location was not cleared")
        XCTAssertTrue(sydney.exists, "swipe-delete removed the wrong location")

        // Clear All takes the remainder.
        let clearAll = app.buttons["Clear All Locations"]
        XCTAssertTrue(clearAll.waitForExistence(timeout: 5), "Clear All Locations not offered")
        clearAll.tap()
        // The confirmation dialog repeats the label; tap the one in the sheet.
        let confirm = app.sheets.buttons["Clear All Locations"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5),
                      "clear-all confirmation dialog did not appear")
        confirm.tap()

        XCTAssertTrue(sydney.waitForNonExistence(timeout: 5),
                      "Clear All Locations left a location behind")

        // Back on the list the payee is gone entirely — no empty rows.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["No Recorded Locations"].waitForExistence(timeout: 5),
                      "cleared payee still listed after clearing its last location")
    }

    /// Against a server that predates payee locations the whole feature is
    /// hidden — clearing would write CRDT messages the server drops, so the
    /// screen must not offer it.
    @MainActor
    func testScreenIsHiddenWhenServerLacksLocationSupport() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "4"]
        app.launch()

        let transactionSettings = app.buttons["Transactions & Automation"]
        XCTAssertTrue(transactionSettings.waitForExistence(timeout: 5))
        transactionSettings.tap()

        // Walk the whole destination form; neither the row nor the toggle appears.
        let row = app.buttons["Payee Locations"]
        let toggle = app.switches["Record Payee Locations"]
        scrollTo(row, in: app)
        XCTAssertFalse(row.exists, "Payee Locations row should be hidden below server 26.4.0")
        XCTAssertFalse(toggle.exists, "Record Payee Locations toggle should be hidden too")
    }
}
