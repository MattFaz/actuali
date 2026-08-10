import XCTest

/// Regression test for the "Last Background Refresh" Settings row showing
/// "Never" forever. The row's @State snapshot is taken once per process
/// launch, but the background task fires while the app is suspended (same
/// process), so the row must re-read the timestamp when the app reactivates.
///
/// A real BGTask fire can't be triggered from a UI test, so the app stands
/// one in behind the -stampBackgroundRefreshOnBackground debug argument: it
/// writes the same timestamp handle() writes when the app enters background.
final class BackgroundRefreshRowUITests: XCTestCase {

    @MainActor
    func testRowUpdatesAfterBackgroundStamp() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "4",
                               "-stampBackgroundRefreshOnBackground"]
        app.launch()

        // The Sync section sits below the fold; SwiftUI forms only create
        // rows on screen, so scroll until the row exists.
        let row = app.staticTexts["Last Background Refresh"]
        var swipes = 0
        while !row.exists && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "Last Background Refresh row not found")
        let never = app.staticTexts["Never"]
        XCTAssertTrue(never.exists, "row should start at Never on a clean slate")

        // Background (stamps the timestamp) and reactivate the same process.
        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(never.waitForNonExistence(timeout: 5),
                      "row still shows Never after a refresh fired while backgrounded")
        XCTAssertTrue(row.exists, "row disappeared after reactivation")

        // Backgrounding also submits a wake request, so the companion
        // diagnostic row must show a timestamp by now too.
        XCTAssertTrue(app.staticTexts["Last Refresh Request"].exists,
                      "Last Refresh Request row not found after reactivation")
    }
}
