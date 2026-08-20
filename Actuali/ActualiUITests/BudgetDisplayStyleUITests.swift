import XCTest

/// Budget layout preferences exercised through the user-visible Budget tab.
final class BudgetDisplayStyleUITests: XCTestCase {

    @MainActor private func budgetedCaption(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH 'Budgeted:'"))
            .firstMatch
    }

    @MainActor
    private func tapSwitch(_ toggle: XCUIElement) {
        let control = toggle.switches.firstMatch
        (control.exists ? control : toggle).tap()
    }

    @MainActor
    private func scrollToSettingsControl(_ control: XCUIElement, in app: XCUIApplication) {
        var swipesLeft = 8
        while !control.exists && swipesLeft > 0 {
            app.swipeUp()
            swipesLeft -= 1
        }
    }

    @MainActor
    func testCleanStyleIsDefaultAndShowsCaptions() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()

        app.tabBars.buttons["Budget"].tap()

        let groceries = app.buttons["Details for Groceries"].firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 10),
                      "demo data should show the Essentials categories")
        XCTAssertTrue(app.buttons["budgetFilter-all"].exists,
                      "the fixed check-in strip should stay visible above the category groups")
        XCTAssertTrue(budgetedCaption(in: app).waitForExistence(timeout: 10),
                      "clean rows carry a 'Budgeted:' caption")
    }

    @MainActor
    func testOptionsMenuTogglesLayoutLive() throws {
        let app = XCUIApplication()
        // Seed clean explicitly: argument-domain values are volatile (the
        // init write-back was removed in actios-96wa), so this can't leak
        // into other tests, but a live tap below persists for real — start
        // from a known state regardless of what earlier runs left behind.
        app.launchArguments = [
            "-loadDemoData",
            "-budgetDisplayStyle", "clean",
            "-showListBudgetOverview", "YES",
        ]
        app.launch()

        app.tabBars.buttons["Budget"].tap()
        XCTAssertTrue(budgetedCaption(in: app).waitForExistence(timeout: 10),
                      "starts in the clean layout")

        let optionsMenu = app.buttons["Budget options"]
        XCTAssertTrue(optionsMenu.waitForExistence(timeout: 10),
                      "the budget toolbar should offer the options menu")
        optionsMenu.tap()
        app.buttons["List"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["listBudgetOverview"]
                .waitForExistence(timeout: 5),
            "switching to List replaces the Clean presentation live"
        )

        optionsMenu.tap()
        app.buttons["Detailed"].tap()
        XCTAssertFalse(budgetedCaption(in: app).waitForExistence(timeout: 5),
                       "detailed rows replace the captions")

        optionsMenu.tap()
        app.buttons["Clean"].tap()
        XCTAssertTrue(budgetedCaption(in: app).waitForExistence(timeout: 5),
                      "toggling back restores the clean rows")
    }

    @MainActor
    func testDetailedStyleShowsPillTableWithoutCaptions() throws {
        let app = XCUIApplication()
        // NSArgumentDomain: seeds the persisted preference for this launch.
        app.launchArguments = ["-loadDemoData", "-budgetDisplayStyle", "detailed"]
        app.launch()

        app.tabBars.buttons["Budget"].tap()

        let groceries = app.buttons["Details for Groceries"].firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 10),
                      "demo data should show the Essentials categories")
        XCTAssertFalse(budgetedCaption(in: app).exists,
                       "detailed rows show pill cells, not 'Budgeted:' captions")
    }

    @MainActor
    func testListStyleShowsDistinctOverviewAndAddsSpentColumnLive() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-budgetDisplayStyle", "list",
            "-showListBudgetOverview", "YES",
            "-showListSpentColumn", "NO",
            "-showBudgetProgressBars", "NO",
            "-initialTab", "1",
        ]
        app.launch()

        let overview = app.descendants(matching: .any)["listBudgetOverview"]
        XCTAssertTrue(overview.waitForExistence(timeout: 10),
                      "List should render its source-style pinned overview")
        let checkInStrip = app.buttons["budgetFilter-all"]
        XCTAssertTrue(checkInStrip.waitForExistence(timeout: 5))
        XCTAssertLessThan(
            checkInStrip.frame.maxY,
            overview.frame.minY,
            "the check-in strip should sit above the List overview"
        )
        let essentials = app.buttons["listBudgetGroup.Essentials"]
        XCTAssertTrue(essentials.exists,
                      "List should render a dedicated group header with totals")
        let groceriesDetails = app.buttons["Details for Groceries"].firstMatch
        if essentials.label.contains("collapsed") {
            essentials.tap()
        }
        XCTAssertTrue(groceriesDetails.waitForExistence(timeout: 5))
        XCTAssertFalse(budgetedCaption(in: app).exists,
                       "List rows should not fall through to Clean")

        XCTAssertTrue(essentials.label.contains("budgeted"))
        XCTAssertTrue(essentials.label.contains("balance"))
        essentials.tap()
        XCTAssertTrue(groceriesDetails.waitForNonExistence(timeout: 5),
                       "collapsing the header hides only its category rows")
        XCTAssertTrue(essentials.exists,
                      "a collapsed group keeps its totals header visible")
        essentials.tap()
        XCTAssertTrue(groceriesDetails.waitForExistence(timeout: 5))

        let groceriesSpent = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Transactions for Groceries in '")
        ).firstMatch
        XCTAssertFalse(groceriesSpent.exists,
                       "the Spent column defaults to absent, not an empty placeholder")

        let optionsMenu = app.buttons["Budget options"]
        optionsMenu.tap()
        let spentToggle = app.buttons["Show Spent Column"]
        XCTAssertTrue(spentToggle.waitForExistence(timeout: 5))
        spentToggle.tap()

        XCTAssertTrue(groceriesSpent.waitForExistence(timeout: 5),
                      "turning on Spent should add the existing month-transactions action live")
    }

    @MainActor
    func testListTrackingStyleUsesNativeSummaryAndIncomeColumns() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-loadTrackingDemoData",
            "-budgetDisplayStyle", "list",
            "-showListBudgetOverview", "YES",
            "-showListSpentColumn", "NO",
            "-collapsedBudgetGroups", "",
            "-initialTab", "1",
        ]
        app.launch()

        let overview = app.descendants(matching: .any)["listBudgetOverview"]
        XCTAssertTrue(overview.waitForExistence(timeout: 10))
        XCTAssertTrue(overview.staticTexts["Income"].exists)
        XCTAssertTrue(overview.staticTexts["Projected"].exists)
        XCTAssertFalse(overview.staticTexts["To Budget"].exists,
                       "tracking budgets have no To Budget value")

        let incomeSection = app.descendants(matching: .any)["listIncomeSection"]
        var scrollsLeft = 12
        while !incomeSection.exists && scrollsLeft > 0 {
            app.swipeUp()
            scrollsLeft -= 1
        }
        XCTAssertTrue(incomeSection.exists)
        XCTAssertTrue(incomeSection.staticTexts["Budgeted"].exists)
        XCTAssertTrue(incomeSection.staticTexts["Received"].exists)
        XCTAssertFalse(incomeSection.staticTexts["Balance"].exists,
                       "Income must not fabricate a Balance column")
        let salary = app.buttons["All transactions for Salary"]
        if !salary.exists {
            app.swipeUp()
        }
        XCTAssertTrue(salary.waitForExistence(timeout: 5),
                      "Income remains expanded")
        let salaryBudget = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH 'Budgeted for Salary, '")
        ).firstMatch
        XCTAssertTrue(
            salaryBudget.exists,
            "tracking Income's read-only budget needs its own currency-aware VoiceOver context"
        )
        XCTAssertTrue(salaryBudget.label.contains("$"))
        XCTAssertFalse(
            salaryBudget.elementType == .button,
            "tracking Income budget remains read-only in List"
        )
    }

    @MainActor
    func testListOptionalOverviewAndSharedProgressBarsAffectPresentation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-budgetDisplayStyle", "list",
            "-showListBudgetOverview", "NO",
            "-showBudgetProgressBars", "NO",
            "-collapsedBudgetGroups", "",
            "-initialTab", "1",
        ]
        app.launch()

        let essentials = app.buttons["listBudgetGroup.Essentials"]
        XCTAssertTrue(essentials.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["listBudgetOverview"].exists,
                       "the optional overview must leave no placeholder")
        let groceries = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Details for Groceries'")
        ).firstMatch
        if essentials.label.contains("collapsed") {
            essentials.tap()
        }
        XCTAssertTrue(groceries.waitForExistence(timeout: 5),
                      "the progress assertions require an expanded fixture group")
        XCTAssertEqual(groceries.label, "Details for Groceries")
        let progressBar = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH 'Partially spent, spent '")
        ).firstMatch
        XCTAssertFalse(progressBar.exists,
                       "disabled progress mode displays neither status dot nor bar")

        app.tabBars.buttons["Settings"].tap()
        let sharedProgressBars = app.switches["Budget Progress Bars"]
        scrollToSettingsControl(sharedProgressBars, in: app)
        XCTAssertTrue(sharedProgressBars.waitForExistence(timeout: 5))
        tapSwitch(sharedProgressBars)
        app.tabBars.buttons["Budget"].tap()
        let groceriesWithStatus = app.buttons.matching(
            NSPredicate(format: "label == 'Details for Groceries, Partially spent'")
        ).firstMatch
        XCTAssertTrue(
            groceriesWithStatus.waitForExistence(timeout: 5),
            "progress mode adds a compact semantic status cue"
        )
        XCTAssertTrue(
            progressBar.waitForExistence(timeout: 5),
            "progress mode adds a bar for an active category"
        )

        app.tabBars.buttons["Settings"].tap()
        tapSwitch(sharedProgressBars)
        app.tabBars.buttons["Budget"].tap()
        XCTAssertTrue(groceriesWithStatus.waitForNonExistence(timeout: 5))
        XCTAssertTrue(progressBar.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Details for Groceries"].exists)
    }

    @MainActor
    func testListAccessibilityDynamicTypeUsesStackedPresentation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-budgetDisplayStyle", "list",
            "-showListBudgetOverview", "YES",
            "-collapsedBudgetGroups", "",
            "-initialTab", "1",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["listBudgetOverview.stacked"]
                .waitForExistence(timeout: 10),
            "accessibility text sizes select the stacked overview"
        )
        let editGroceries = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Edit budgeted amount for Groceries'")
        ).firstMatch
        var scrollsLeft = 8
        while !editGroceries.exists && scrollsLeft > 0 {
            app.swipeUp()
            scrollsLeft -= 1
        }
        XCTAssertTrue(
            editGroceries.waitForExistence(timeout: 5),
            "stacking keeps category amount actions available without compact-cell shrinking"
        )
    }

    @MainActor
    func testListLongNamesRemainDiscoverableWhileAmountsArePrivate() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-budgetDisplayStyle", "list",
            "-hideBalances", "YES",
            "-collapsedBudgetGroups", "",
            "-initialTab", "1",
        ]
        app.launch()

        let groceriesBudget = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Edit budgeted amount for Groceries'")
        ).firstMatch
        XCTAssertTrue(groceriesBudget.waitForExistence(timeout: 10))
        XCTAssertTrue(groceriesBudget.label.contains("••••"),
                      "privacy masking also covers action accessibility values")

        let longGroup = app.buttons["listBudgetGroup.Health & Wellness"]
        var scrollsLeft = 10
        while !longGroup.exists && scrollsLeft > 0 {
            app.swipeUp()
            scrollsLeft -= 1
        }
        XCTAssertTrue(longGroup.exists,
                      "long group names remain exposed without truncating their identity")
        XCTAssertTrue(longGroup.label.contains("••••"),
                      "group totals respect global privacy masking")

        let longCategory = app.buttons["All transactions for Starting Balances"]
        scrollsLeft = 10
        while !longCategory.exists && scrollsLeft > 0 {
            app.swipeUp()
            scrollsLeft -= 1
        }
        XCTAssertTrue(longCategory.exists,
                      "long category names remain exposed in the fixed title column")
    }

    @MainActor
    func testCategoryNameOpensCompactEditor() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData", "-budgetDisplayStyle", "clean", "-initialTab", "1",
        ]
        app.launch()

        let groceries = app.buttons["Details for Groceries"].firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 10))
        groceries.tap()

        XCTAssertTrue(app.navigationBars["Edit Category"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["Category Name"].exists)
        XCTAssertTrue(app.staticTexts["Note"].exists)
        XCTAssertTrue(app.staticTexts["Quick Assign"].exists)
        XCTAssertFalse(app.buttons["This Month's Transactions"].exists)
        XCTAssertFalse(app.buttons["All Transactions"].exists)
        XCTAssertFalse(app.staticTexts["Actions"].exists)
    }

    @MainActor
    func testCheckInStripFiltersUnassignedCategoriesInPlace() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "1"]
        app.launch()

        // Parking has no activity in the demo. Clearing its budget makes it
        // a real Not Funded check-in result through the normal write path.
        let editParking = app.buttons["Edit budgeted amount for Parking"]
        // Slow swipes: the pinned summary and status strip leave a short List
        // viewport, and a full-velocity swipe scrolls Parking straight past
        // the hittable band and off the other side.
        var scrollsLeft = 20
        while !editParking.isHittable && scrollsLeft > 0 {
            app.swipeUp(velocity: .slow)
            scrollsLeft -= 1
        }
        XCTAssertTrue(editParking.isHittable, "Parking's edit button not reachable")
        editParking.tap()

        let amount = app.textFields.firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10))
        app.buttons["Save"].tap()
        XCTAssertTrue(amount.waitForNonExistence(timeout: 5))

        for _ in 0..<8 { app.swipeDown() }
        tapBudgetFilter(app, "unassigned")

        XCTAssertTrue(app.buttons["Details for Parking"].waitForExistence(timeout: 5),
                      "the horizontal check-in filter keeps matching categories in the budget table")
        XCTAssertFalse(app.buttons["Details for Groceries"].exists)
    }
}
