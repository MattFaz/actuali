import XCTest

/// The settings `Form` carries the window's safe-area inset in its content
/// margin (`SideMargin.clearOfSideBar()`), because a `Form` given horizontal
/// content margins draws its rows under iPhone Duo's 84 pt side bar. A plain
/// phone has no horizontal inset, so the same code must leave the rows exactly
/// where they were — this pins that, since the Duo has no CI runtime.
final class SettingsMarginsUITests: XCTestCase {
    /// What an inset-grouped `Form` gives its rows on a phone.
    private let expectedMargin: CGFloat = 20
    /// Sub-point slack for rounding in the rendered frame.
    private let tolerance: CGFloat = 2

    @MainActor
    func testSettingsRowsKeepTheirSideMargins() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "4"]
        app.launch()

        let label = app.staticTexts["Connection & Data"].firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 20), "the settings list never appeared")

        let row = app.cells.containing(.staticText, identifier: "Connection & Data").firstMatch
        let frame = row.exists ? row.frame : label.frame
        let window = app.windows.firstMatch.frame

        XCTAssertEqual(frame.minX - window.minX, expectedMargin, accuracy: tolerance)
        XCTAssertEqual(window.maxX - frame.maxX, expectedMargin, accuracy: tolerance)
    }
}
