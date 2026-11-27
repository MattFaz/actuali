import XCTest

final class ReportDetailRangeUITests: XCTestCase {
    /// Picking a range covers the report with placeholders while it loads.
    /// The page's title and the picker are not part of the report.
    @MainActor
    func testPickingARangeKeepsTheTitleAndThePicker() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "3", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'reportCard.'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()

        let range = app.buttons["reportDetail.range.3M"]
        XCTAssertTrue(range.waitForExistence(timeout: 5))
        let title = app.navigationBars.firstMatch.identifier
        XCTAssertFalse(title.isEmpty)

        range.tap()
        XCTAssertTrue(app.navigationBars[title].staticTexts[title].exists)
        XCTAssertTrue(range.isSelected)
        XCTAssertTrue(app.buttons["reportDetail.range.Saved"].isHittable)
        // The report comes back once the range has loaded.
        XCTAssertTrue(app.descendants(matching: .any)["reportDetail.readout"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars[title].staticTexts[title].exists)

        // Scrubbing pins an interval; the readout's corner clears it.
        let clear = app.buttons["reportDetail.clearSelection"]
        XCTAssertFalse(clear.exists)
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.55))
            .press(forDuration: 0.3, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.55)))
        XCTAssertTrue(clear.waitForExistence(timeout: 3))
        clear.tap()
        XCTAssertFalse(clear.exists)
    }
}
