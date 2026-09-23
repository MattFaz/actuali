import XCTest

/// The Budget summary bar is pinned outside the scrolling table (GH #155), so
/// it can't move with the table. Any navigation bar that resizes with the
/// scroll — a large title stretching on overscroll, or collapsing on scroll-up
/// — therefore slides over it (GH #253). Assert the bar stays a fixed height.
final class BudgetSummaryPinUITests: XCTestCase {
    @MainActor
    func testBudgetNavigationBarDoesNotResizeWithScrolling() {
        let app = XCUIApplication()
        // Pin the style: "Details for Groceries" is the Clean row's exact
        // label; Compact appends the category's status to it.
        app.launchArguments = ["-loadDemoData", "-budgetDisplayStyle", "clean"]
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
    func testMonthStepperStaysReachableAfterScrolling() {
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
    func testMonthStepperIsCenteredInTheBar() {
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

    @MainActor
    func testTopBoxInsetsMatchBetweenBudgetAndAccounts() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-budgetDisplayStyle", "clean",
            "-showCompactBudgetOverview", "YES",
            // The status strip now sits above the summary in both styles, so
            // hide it here: this test measures the summary cards themselves.
            "-showBudgetCheckInStrip", "NO",
            "-initialTab", "1",
        ]
        app.launch()

        app.tabBars.buttons["Budget"].tap()
        let budgetBox = app.descendants(matching: .any)
            .matching(identifier: "budget.topBox")
            .firstMatch
        XCTAssertTrue(budgetBox.waitForExistence(timeout: 10),
                      "the clean budget summary should be visible")
        let budgetNavBar = app.navigationBars.firstMatch
        XCTAssertTrue(budgetNavBar.exists)
        let budgetFrame = budgetBox.frame
        let budgetWindow = app.windows.firstMatch.frame
        let budgetTopGap = budgetFrame.minY - budgetNavBar.frame.maxY
        let budgetLeadingInset = budgetFrame.minX - budgetWindow.minX
        let budgetTrailingInset = budgetWindow.maxX - budgetFrame.maxX

        app.tabBars.buttons["Accounts"].tap()
        let accountsBox = app.descendants(matching: .any)
            .matching(identifier: "accounts.topBox")
            .firstMatch
        XCTAssertTrue(accountsBox.waitForExistence(timeout: 10),
                      "the accounts summary should be visible")
        let accountsNavBar = app.navigationBars.firstMatch
        XCTAssertTrue(accountsNavBar.exists)
        let accountsFrame = accountsBox.frame
        let accountsWindow = app.windows.firstMatch.frame

        XCTAssertEqual(accountsFrame.minY - accountsNavBar.frame.maxY,
                       budgetTopGap, accuracy: 2,
                       "the first summary should have the same toolbar gap")
        XCTAssertEqual(accountsFrame.minX - accountsWindow.minX,
                       budgetLeadingInset, accuracy: 2,
                       "the summary boxes should share a leading inset")
        XCTAssertEqual(accountsWindow.maxX - accountsFrame.maxX,
                       budgetTrailingInset, accuracy: 2,
                       "the summary boxes should share a trailing inset")
    }
}
