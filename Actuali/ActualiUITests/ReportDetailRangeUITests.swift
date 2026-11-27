import XCTest

final class ReportDetailRangeUITests: XCTestCase {
    /// Picking a range covers the report with placeholders while it loads.
    /// The page's title and the picker are not part of the report.
    @MainActor
    func testPickingARangeKeepsTheTitleAndThePicker() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "3", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'reportCard.' AND label CONTAINS 'Net Worth'"))
            .firstMatch
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
        // The chart sits right under the readout, whatever the screen size.
        let readout = app.descendants(matching: .any)["reportDetail.readout"]
        let chartLeft = readout.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 1)).withOffset(CGVector(dx: 60, dy: 120))
        chartLeft.press(forDuration: 0.3, thenDragTo: chartLeft.withOffset(CGVector(dx: 120, dy: 0)))
        XCTAssertTrue(clear.waitForExistence(timeout: 3))
        clear.tap()
        XCTAssertFalse(clear.exists)
    }
}
