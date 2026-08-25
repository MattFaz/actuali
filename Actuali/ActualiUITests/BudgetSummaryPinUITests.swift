import XCTest

/// The Budget summary bar is pinned outside the scrolling table (GH #155), so
/// it can't move with the table. Any navigation bar that resizes with the
/// scroll — a large title stretching on overscroll, or collapsing on scroll-up
/// — therefore slides over it (GH #253). Assert the bar stays a fixed height.
final class BudgetSummaryPinUITests: XCTestCase {

    @MainActor
    func testBudgetNavigationBarDoesNotResizeWithScrolling() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()

        app.tabBars.buttons["Budget"].tap()

        let groceries = app.buttons["Details for Groceries"].firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 10),
                      "demo data should show the Essentials categories")

        let navBar = app.navigationBars.firstMatch
        XCTAssertTrue(navBar.waitForExistence(timeout: 10),
                      "the Budget tab should have a navigation bar")
        let restingHeight = navBar.frame.height

        app.swipeUp()
        XCTAssertEqual(navBar.frame.height, restingHeight, accuracy: 1,
                       "a collapsing large title drags the pinned summary up with it")

        app.swipeDown()
        XCTAssertEqual(navBar.frame.height, restingHeight, accuracy: 1,
                       "pulling to refresh must not stretch the bar over the summary")
    }

    @MainActor
    func testMonthStepperStaysReachableAfterScrolling() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()

        app.tabBars.buttons["Budget"].tap()

        let nextMonth = app.buttons["Next month"]
        XCTAssertTrue(nextMonth.waitForExistence(timeout: 10),
                      "the month stepper lives in the bar")

        app.swipeUp()
        XCTAssertTrue(nextMonth.isHittable,
                      "the inline bar keeps the stepper tappable while scrolled")
    }

    /// UIKit silently gives up on centering a title view once it outgrows the
    /// slot the trailing buttons leave, and jams it against the leading edge
    /// instead — twice now (GH #234, #319). Only the rendered frames catch it,
    /// and the stepper clears the slot by 2pt, so this is the guard for the
    /// next thing that widens it.
    @MainActor
    func testMonthStepperIsCenteredInTheBar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()

        app.tabBars.buttons["Budget"].tap()

        let navBar = app.navigationBars.firstMatch
        let previousMonth = navBar.buttons["Previous month"]
        XCTAssertTrue(previousMonth.waitForExistence(timeout: 10),
                      "the month stepper lives in the bar")
        let nextMonth = navBar.buttons["Next month"]

        let stepperMidX = (previousMonth.frame.minX + nextMonth.frame.maxX) / 2
        XCTAssertEqual(stepperMidX, navBar.frame.midX, accuracy: 4,
                       "the month stepper must stay centered in the bar")
    }
}
