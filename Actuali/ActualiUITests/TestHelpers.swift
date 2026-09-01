import XCTest

extension XCTestCase {
    /// Open Settings > Budget View whether Settings last showed its hub or
    /// retained the destination from an earlier tab visit.
    @MainActor
    func openBudgetViewSettings(in app: XCUIApplication) {
        app.tabBars.buttons["More"].tap()
        if app.navigationBars["Budget View"].waitForExistence(timeout: 2) {
            return
        }

        let row = app.buttons["Budget View"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Budget View settings row not found")
        row.tap()
        XCTAssertTrue(app.navigationBars["Budget View"].waitForExistence(timeout: 5))
    }

    /// Tap a status chip in the Budget tab's check-in strip.
    ///
    /// The strip scrolls horizontally and holds more chips than fit on a
    /// phone, so a chip can exist while sitting off-screen — `tap()` alone
    /// fails on those. Walk the strip until the chip is reachable.
    @MainActor
    func tapBudgetFilter(_ app: XCUIApplication, _ filter: String) {
        let chip = app.buttons["budgetFilter-\(filter)"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10),
                      "\(filter) filter chip missing from the check-in strip")
        guard !chip.isHittable else {
            chip.tap()
            return
        }
        let strip = app.scrollViews.firstMatch
        for _ in 0..<5 where !chip.isHittable { strip.swipeLeft() }
        for _ in 0..<10 where !chip.isHittable { strip.swipeRight() }
        XCTAssertTrue(chip.isHittable, "\(filter) filter chip not reachable in the strip")
        chip.tap()
    }
}
