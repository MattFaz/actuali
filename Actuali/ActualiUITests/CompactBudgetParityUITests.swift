import XCTest

final class CompactBudgetParityUITests: XCTestCase {
    @MainActor
    func testExpenseCellsReachExistingActionFlows() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-budgetDisplayStyle", "compact",
            "-showCompactSpentColumn", "YES",
            "-showBudgetProgressBars", "NO",
            "-showCategoryStatusDots", "NO",
            "-useNarrowCurrencySymbol", "YES",
            "-initialTab", "1",
        ]
        app.launch()

        let details = app.buttons["Details for Groceries"]
        ensureGroupExpanded("Essentials", revealing: details, in: app)
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["budgetFilter-all"].exists)
        XCTAssertTrue(app.buttons["Previous month"].exists)
        XCTAssertTrue(app.buttons["Next month"].exists)

        details.press(forDuration: 1)
        let allTransactions = app.buttons["All Transactions"]
        XCTAssertTrue(allTransactions.waitForExistence(timeout: 5))
        allTransactions.tap()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["All Time"].exists)
        app.navigationBars.buttons["Budget"].tap()

        let add = app.navigationBars["Budget"].buttons["Add"]
        XCTAssertTrue(add.exists, "Compact keeps the shared category creation menu")
        add.tap()
        XCTAssertTrue(app.buttons["New Category"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["New Category Group"].exists)
        app.buttons["New Category Group"].tap()
        XCTAssertTrue(app.navigationBars["New Group"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()

        details.tap()
        XCTAssertTrue(app.navigationBars["Edit Category"].waitForExistence(timeout: 5),
                      "the category name opens the existing category editor")
        app.buttons["Cancel"].tap()

        let editBudget = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Edit budgeted amount for Groceries'")
        ).firstMatch
        XCTAssertTrue(editBudget.waitForExistence(timeout: 5))
        XCTAssertTrue(editBudget.label.contains("$"),
                      "VoiceOver gets the full budget-currency value while the cell omits its symbol")
        editBudget.tap()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5),
                      "Budgeted opens the existing edit sheet")
        XCTAssertTrue(app.textFields.firstMatch.exists)
        app.buttons["Cancel"].tap()

        let spent = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Transactions for Groceries in '")
        ).firstMatch
        XCTAssertTrue(spent.waitForExistence(timeout: 5))
        XCTAssertTrue(spent.label.contains("$"))
        XCTAssertTrue(spent.label.contains(currentMonthTitle()),
                      "Spent targets the displayed month")
        spent.tap()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5),
                      "Spent opens the category's transaction destination")
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons["Budget"].tap()

        let balance = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Move money from Groceries'")
        ).firstMatch
        XCTAssertTrue(balance.waitForExistence(timeout: 5))
        XCTAssertTrue(balance.label.contains("$"))
        XCTAssertTrue(balance.label.contains("positive"),
                      "VoiceOver communicates balance status without relying on green")
        balance.tap()
        XCTAssertTrue(app.navigationBars["Move Money"].waitForExistence(timeout: 5),
                      "a nonzero Balance opens the existing move-money sheet")
        app.buttons["Cancel"].tap()
    }

    @MainActor
    func testKeepsSharedMonthSwipeNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-budgetDisplayStyle", "compact",
            "-initialTab", "1",
        ]
        app.launch()

        let currentMonth = monthTitle(offset: 0)
        let nextMonth = monthTitle(offset: 1)
        XCTAssertTrue(app.buttons[currentMonth].waitForExistence(timeout: 10))

        app.swipeLeft()
        XCTAssertTrue(app.buttons[nextMonth].waitForExistence(timeout: 5),
                      "the shared horizontal gesture advances Compact by one month")
        app.swipeRight()
        XCTAssertTrue(app.buttons[currentMonth].waitForExistence(timeout: 5))
    }

    @MainActor
    func testCategoryFilterUsesSharedEmptyAndRecoveryFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-budgetDisplayStyle", "compact",
            "-initialTab", "1",
        ]
        app.launch()

        let groceries = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Details for Groceries'")
        ).firstMatch
        ensureGroupExpanded("Essentials", revealing: groceries, in: app)
        XCTAssertTrue(groceries.waitForExistence(timeout: 10))
        tapBudgetFilter(app, "overspent")

        XCTAssertTrue(app.staticTexts["No Matching Categories"].waitForExistence(timeout: 5))
        XCTAssertFalse(groceries.exists)
        app.buttons["Show All Categories"].tap()
        XCTAssertTrue(groceries.waitForExistence(timeout: 5))
    }

    @MainActor
    func testEmptyCategoryStatusDotAndProgressBarRespectIndependentSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-budgetDisplayStyle", "compact",
            "-showBudgetProgressBars", "YES",
            "-showCategoryStatusDots", "YES",
            "-initialTab", "1",
        ]
        app.launch()

        let editParking = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Edit budgeted amount for Parking'")
        ).firstMatch
        ensureGroupExpanded("Transport", revealing: editParking, in: app)
        scrollUntilHittable(editParking, in: app)
        XCTAssertTrue(editParking.waitForExistence(timeout: 5))
        editParking.tap()

        let amount = app.textFields.firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10))
        app.buttons["Save"].tap()
        XCTAssertTrue(amount.waitForNonExistence(timeout: 5))

        let emptyStatus = app.buttons["Details for Parking, No money assigned"]
        XCTAssertTrue(emptyStatus.waitForExistence(timeout: 5),
                      "the status-dot setting describes an empty category")
        let emptyBar = app.descendants(matching: .any)["No money assigned, spent 0 percent"]
        XCTAssertFalse(emptyBar.exists,
                       "a category with no budget or activity has no progress to visualize")

        openBudgetViewSettings(in: app)
        let sharedProgressBars = app.switches["Budget Progress Bars"]
        scrollUntilHittable(sharedProgressBars, in: app)
        XCTAssertTrue(sharedProgressBars.waitForExistence(timeout: 5))
        tapSwitch(sharedProgressBars)
        app.tabBars.buttons["Budget"].tap()
        XCTAssertTrue(emptyStatus.waitForExistence(timeout: 5),
                      "turning off progress bars leaves status dots alone")
        XCTAssertFalse(emptyBar.exists)

        openBudgetViewSettings(in: app)
        tapSwitch(sharedProgressBars)
        let statusDots = app.switches["Category Status Dots"]
        scrollUntilHittable(statusDots, in: app)
        XCTAssertTrue(statusDots.waitForExistence(timeout: 5))
        tapSwitch(statusDots)
        app.tabBars.buttons["Budget"].tap()
        XCTAssertTrue(emptyStatus.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Details for Parking"].exists)
        XCTAssertFalse(emptyBar.exists)

        openBudgetViewSettings(in: app)
        tapSwitch(statusDots)
    }

    @MainActor
    func testIncomeNameAndReceivedReachTheirTransactionScopes() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-loadTrackingDemoData",
            "-budgetDisplayStyle", "compact",
            "-initialTab", "1",
        ]
        app.launch()

        let salary = app.buttons["All transactions for Salary"]
        scrollUntilHittable(salary, in: app)
        XCTAssertTrue(salary.waitForExistence(timeout: 5))
        salary.tap()
        XCTAssertTrue(app.navigationBars["Salary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["All Time"].exists,
                      "the Income name opens all-time transactions")
        app.navigationBars.buttons["Budget"].tap()

        let received = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Transactions for Salary in '")
        ).firstMatch
        scrollUntilHittable(received, in: app)
        XCTAssertTrue(received.waitForExistence(timeout: 5))
        received.tap()
        XCTAssertTrue(app.navigationBars["Salary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[currentMonthTitle()].exists,
                      "Received opens transactions for the displayed month")
    }

    @MainActor
    func testIncomeContextMenuHidesAndShowsCategory() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData", "-budgetDisplayStyle", "compact",
            "-showHiddenCategories", "YES", "-initialTab", "1",
        ]
        app.launch()

        let salary = app.buttons["All transactions for Salary"]
        scrollUntilHittable(salary, in: app)
        XCTAssertTrue(salary.isHittable)
        salary.press(forDuration: 1)
        let hide = app.buttons["Hide"].firstMatch
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
        hide.tap()

        // Hidden rows stay visible in this mode, so the inverse action must appear.
        scrollUntilHittable(salary, in: app)
        salary.press(forDuration: 1)
        let show = app.buttons["Show"].firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        show.tap()

        salary.press(forDuration: 1)
        XCTAssertTrue(hide.waitForExistence(timeout: 5))
    }

    @MainActor
    private func scrollUntilHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxSwipes: Int = 12
    ) {
        var swipesLeft = maxSwipes
        while !element.isHittable && swipesLeft > 0 {
            app.swipeUp()
            swipesLeft -= 1
        }
    }

    @MainActor
    private func ensureGroupExpanded(
        _ name: String,
        revealing element: XCUIElement,
        in app: XCUIApplication
    ) {
        let group = app.buttons["compactBudgetGroup.\(name)"]
        scrollUntilHittable(group, in: app)
        XCTAssertTrue(group.isHittable)
        if group.label.contains("collapsed") {
            group.tap()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
    }

    @MainActor
    private func tapSwitch(_ toggle: XCUIElement) {
        let control = toggle.switches.firstMatch
        (control.exists ? control : toggle).tap()
    }

    private func currentMonthTitle() -> String {
        monthTitle(offset: 0)
    }

    private func monthTitle(offset: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        let date = Calendar.current.date(byAdding: .month, value: offset, to: Date()) ?? Date()
        return formatter.string(from: date)
    }
}
