import XCTest

final class FilterChipUITests: XCTestCase {
    /// A declared 44pt target measures 43.999999999999986; name the float
    /// tolerance so a real shrink still fails.
    private let minimumTapTarget: CGFloat = 43.999

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
        XCTAssertGreaterThanOrEqual(overspent.frame.height, minimumTapTarget)

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
        XCTAssertGreaterThanOrEqual(transactionAll.frame.width, minimumTapTarget)
        XCTAssertGreaterThanOrEqual(transactionAll.frame.height, minimumTapTarget)
        let uncategorized = app.buttons["transactionFilter-uncategorized"]
        XCTAssertGreaterThanOrEqual(uncategorized.frame.height, minimumTapTarget)
        for offset in [-19.0, 19.0] {
            uncategorized.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .withOffset(CGVector(dx: 0, dy: offset)).tap()
            XCTAssertTrue(uncategorized.wait(for: \.isSelected, toEqual: true, timeout: 5))
            transactionAll.tap()
            XCTAssertTrue(transactionAll.wait(for: \.isSelected, toEqual: true, timeout: 5))
        }
    }
}
