import XCTest

final class ListBudgetParityUITests: XCTestCase {
    @MainActor
    func testExpenseCellsReachExistingActionFlows() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-budgetDisplayStyle", "list",
            "-showListSpentColumn", "YES",
            "-showBudgetProgressBars", "NO",
            "-initialTab", "1",
        ]
        app.launch()

        let details = app.buttons["Details for Groceries"]
        ensureGroupExpanded("Essentials", revealing: details, in: app)
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Budget Check-In"].exists)
        XCTAssertTrue(app.buttons["Previous month"].exists)
        XCTAssertTrue(app.buttons["Next month"].exists)

        let add = app.navigationBars["Budget"].buttons["Add"]
        XCTAssertTrue(add.exists, "List keeps the shared category creation menu")
        add.tap()
        XCTAssertTrue(app.buttons["New Category"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["New Category Group"].exists)
        app.buttons["New Category Group"].tap()
        XCTAssertTrue(app.navigationBars["New Group"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()

        details.tap()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5),
                      "the category name opens the existing detail sheet")
        app.buttons["Done"].tap()

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
        spent.tap()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5),
                      "Spent opens the category's transaction destination")
        XCTAssertTrue(app.staticTexts[currentMonthTitle()].waitForExistence(timeout: 5),
                      "Spent scopes transactions to the displayed month")
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
            "-budgetDisplayStyle", "list",
            "-initialTab", "1",
        ]
        app.launch()

        let currentMonth = monthTitle(offset: 0)
        let nextMonth = monthTitle(offset: 1)
        XCTAssertTrue(app.buttons[currentMonth].waitForExistence(timeout: 10))

        app.swipeLeft()
        XCTAssertTrue(app.buttons[nextMonth].waitForExistence(timeout: 5),
                      "the shared horizontal gesture advances List by one month")
        app.swipeRight()
        XCTAssertTrue(app.buttons[currentMonth].waitForExistence(timeout: 5))
    }

    @MainActor
    func testCategoryFilterUsesSharedEmptyAndRecoveryFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-budgetDisplayStyle", "list",
            "-initialTab", "1",
        ]
        app.launch()

        let groceries = app.buttons["Details for Groceries"]
        ensureGroupExpanded("Essentials", revealing: groceries, in: app)
        XCTAssertTrue(groceries.waitForExistence(timeout: 10))
        app.buttons["Budget options"].tap()
        app.buttons["Overspent"].tap()

        XCTAssertTrue(app.staticTexts["No Matching Categories"].waitForExistence(timeout: 5))
        XCTAssertFalse(groceries.exists)
        app.buttons["Show All Categories"].tap()
        XCTAssertTrue(groceries.waitForExistence(timeout: 5))
    }

    @MainActor
    func testSharedProgressBarsKeepDotAndBarCombinedForEmptyCategory() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-budgetDisplayStyle", "list",
            "-showBudgetProgressBars", "YES",
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
                      "enabled progress mode keeps the status dot for an empty category")
        let emptyBar = app.descendants(matching: .any)["No money assigned, spent 0 percent"]
        XCTAssertTrue(emptyBar.waitForExistence(timeout: 5),
                      "enabled progress mode pairs every expense status dot with a bar")

        app.tabBars.buttons["Settings"].tap()
        let sharedProgressBars = app.switches["Budget Progress Bars"]
        scrollUntilHittable(sharedProgressBars, in: app)
        XCTAssertTrue(sharedProgressBars.waitForExistence(timeout: 5))
        tapSwitch(sharedProgressBars)
        app.tabBars.buttons["Budget"].tap()
        XCTAssertTrue(emptyStatus.waitForNonExistence(timeout: 5))
        XCTAssertTrue(emptyBar.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Details for Parking"].exists)

        app.tabBars.buttons["Settings"].tap()
        tapSwitch(sharedProgressBars)
    }

    @MainActor
    func testIncomeNameAndReceivedReachTheirTransactionScopes() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-loadTrackingDemoData",
            "-budgetDisplayStyle", "list",
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

    private func ensureGroupExpanded(
        _ name: String,
        revealing element: XCUIElement,
        in app: XCUIApplication
    ) {
        let group = app.buttons["listBudgetGroup.\(name)"]
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
