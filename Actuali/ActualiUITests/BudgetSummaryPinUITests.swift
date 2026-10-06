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
                      "the month stepper lives in the pinned header")

        app.swipeUp()
        XCTAssertTrue(nextMonth.isHittable,
                      "the pinned header keeps the stepper tappable while scrolled")
    }

    @MainActor
    func testMonthStepperIsCenteredInTheHeader() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "1"]
        app.launch()

        assertMonthStepperIsCentered(app)
    }

    @MainActor
    func testLocalizedMonthStepperStaysCenteredAtLargerTextSizes() {
        for language in ["de", "pt-BR"] {
            for size in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryXXXL"] {
                let app = XCUIApplication()
                app.launchArguments = [
                    "-loadDemoData", "-initialTab", "1",
                    "-AppleLanguages", "(\(language))", "-AppleLocale", language,
                    "-UIPreferredContentSizeCategoryName", size,
                ]
                app.launch()

                assertMonthStepperIsCentered(app)
                app.terminate()
            }
        }
    }

    @MainActor private func assertMonthStepperIsCentered(_ app: XCUIApplication) {
        let header = app.descendants(matching: .any)["budget.monthStepper"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        let previous = app.buttons["budget.previousMonth"]
        let next = app.buttons["budget.nextMonth"]
        XCTAssertTrue(previous.isHittable)
        XCTAssertTrue(next.isHittable)
        let midpoint = (previous.frame.minX + next.frame.maxX) / 2
        XCTAssertEqual(midpoint, app.windows.firstMatch.frame.midX, accuracy: 2)
        let navBar = app.navigationBars.firstMatch
        XCTAssertGreaterThanOrEqual(header.frame.minY, navBar.frame.minY - 1)
        XCTAssertLessThanOrEqual(header.frame.maxY, navBar.frame.maxY + 1)
        XCTAssertFalse(navBar.staticTexts["Budget"].exists)
        let actions = app.buttons["budget.actionsMenu"]
        let options = app.buttons["budget.optionsMenu"]
        XCTAssertLessThanOrEqual(actions.frame.maxX, previous.frame.minX)
        XCTAssertGreaterThanOrEqual(options.frame.minX, next.frame.maxX)

        let restingFrame = header.frame
        app.swipeUp()
        XCTAssertEqual(header.frame, restingFrame, "the month header must stay pinned while scrolling")
        XCTAssertTrue(previous.isHittable)
        XCTAssertTrue(next.isHittable)
    }

    @MainActor
    func testTopBoxInsetsMatchBetweenBudgetAndAccounts() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-budgetDisplayStyle", "clean",
            "-showCompactBudgetOverview", "YES",
            "-showCleanBudgetOverview", "YES",
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
        let monthHeader = app.descendants(matching: .any)["budget.monthStepper"]
        XCTAssertTrue(monthHeader.exists)
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

    /// The uncategorized bar sits above the pinned summary. With the status
    /// strip hidden the bar is the top surface, so it keeps the standardized
    /// 8 pt top gutter; `testStatusStripKeepsTheTopGutter` covers the default
    /// layout where the strip is on top. Demo data is fully categorized
    /// on-budget, so `-seedUncategorized` seeds the transaction that makes the
    /// bar render — no other test in the suite can see it.
    @MainActor
    func testUncategorizedBarSitsAboveTheSummary() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-budgetDisplayStyle", "clean",
            "-seedUncategorized",
            "-showCleanBudgetOverview", "YES",
            // The status strip sits above the bar (GH #546); hide it so the
            // bar is the top surface whose gutter this test measures.
            "-showBudgetCheckInStrip", "NO",
        ]
        app.launch()

        app.tabBars.buttons["Budget"].tap()

        let bar = app.descendants(matching: .any)
            .matching(identifier: "budgetUncategorized").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 10),
                      "the seeded uncategorized transaction should render the bar")
        let box = app.descendants(matching: .any)
            .matching(identifier: "budget.topBox").firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 10),
                      "the clean summary should render below the bar")

        XCTAssertLessThanOrEqual(bar.frame.maxY, box.frame.minY,
                                 "the uncategorized bar must stay above the pinned summary")
        let navBar = app.navigationBars.firstMatch
        XCTAssertTrue(navBar.exists)
        XCTAssertEqual(bar.frame.minY - navBar.frame.maxY, 8, accuracy: 2,
                       "the bar must keep the standardized top gutter (TopBoxLayout.verticalContentMargin)")
    }

    /// The status strip is shown by default and has been the top surface
    /// since GH #546, so it keeps the same 8 pt top gutter as every other
    /// top box.
    @MainActor
    func testStatusStripKeepsTheTopGutter() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-budgetDisplayStyle", "clean",
            "-showBudgetCheckInStrip", "YES",
        ]
        app.launch()

        app.tabBars.buttons["Budget"].tap()

        let chip = app.buttons["budgetFilter-all"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10),
                      "the status strip should be the top surface")
        let navBar = app.navigationBars.firstMatch
        XCTAssertTrue(navBar.exists)
        XCTAssertEqual(chip.frame.minY - navBar.frame.maxY, 8, accuracy: 2,
                       "the strip must keep the standardized top gutter (TopBoxLayout.verticalContentMargin)")
    }
}
