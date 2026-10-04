import XCTest

final class FilterChipUITests: XCTestCase {
    @MainActor
    func testCompactChipsKeepFullSizeTapTargets() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-budgetDisplayStyle", "clean",
                               "-showBudgetCheckInStrip", "YES", "-initialTab", "1",
                               "-resetStatusFilterState"]
        app.launch()

        let budgetAll = app.buttons["budgetFilter-all"]
        XCTAssertTrue(budgetAll.waitForExistence(timeout: 15))
        let overspent = app.buttons["budgetFilter-overspent"]
        XCTAssertGreaterThanOrEqual(overspent.frame.height, 44)

        // These taps land outside the 32pt capsule but inside its hit region.
        for offset in [-19.0, 19.0] {
            overspent.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .withOffset(CGVector(dx: 0, dy: offset)).tap()
            XCTAssertTrue(overspent.wait(for: \.isSelected, toEqual: true, timeout: 5))
            budgetAll.tap()
            XCTAssertTrue(budgetAll.wait(for: \.isSelected, toEqual: true, timeout: 5))
        }

        app.tabBars.buttons["Accounts"].tap()
        let accounts = app.staticTexts["All Accounts"].firstMatch
        XCTAssertTrue(accounts.waitForExistence(timeout: 10))
        accounts.tap()
        let transactionAll = app.buttons["transactionFilter-all"]
        XCTAssertTrue(transactionAll.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(transactionAll.frame.width, 44)
        XCTAssertGreaterThanOrEqual(transactionAll.frame.height, 44)
        let uncategorized = app.buttons["transactionFilter-uncategorized"]
        XCTAssertGreaterThanOrEqual(uncategorized.frame.height, 44)
        for offset in [-19.0, 19.0] {
            uncategorized.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .withOffset(CGVector(dx: 0, dy: offset)).tap()
            XCTAssertTrue(uncategorized.wait(for: \.isSelected, toEqual: true, timeout: 5))
            transactionAll.tap()
            XCTAssertTrue(transactionAll.wait(for: \.isSelected, toEqual: true, timeout: 5))
        }
    }
}
