import XCTest

/// Settings > Budget View owns the presentation options that remain outside
/// the Budget tab's contextual display menu. The first test also guards
/// against reintroducing duplicate controls here.
final class BudgetViewSettingsUITests: XCTestCase {
    @MainActor
    private func launchSettings(
        budgetDisplayStyle: String = "clean",
        showCategoryStatusDots: Bool = true,
        showBudgetProgressBars: Bool = true,
        showInverseBudgetProgressBars: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-initialTab", "4",
            "-budgetDisplayStyle", budgetDisplayStyle,
            "-hideZeroBudgetCategories", "NO",
            "-showBudgetedAmounts", "YES",
            "-showCategoryStatusDots", showCategoryStatusDots ? "YES" : "NO",
            "-showBudgetProgressBars", showBudgetProgressBars ? "YES" : "NO",
            "-showInverseBudgetProgressBars", showInverseBudgetProgressBars ? "YES" : "NO",
        ]
        app.launch()
        return app
    }

    @MainActor
    func testDuplicateBudgetDisplayControlsAreAbsentFromSettings() {
        let app = launchSettings()
        openBudgetViewSettings(in: app)

        XCTAssertTrue(
            app.switches["Category Status Dots"].waitForExistence(timeout: 5),
            "Unique presentation settings should remain available"
        )
        XCTAssertTrue(app.switches["Budget Progress Bars"].exists)

        let viewStyle = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'View Style'")
        ).firstMatch
        XCTAssertFalse(viewStyle.exists, "View Style is available from the Budget tab menu")

        for title in [
            "Group Totals",
            "Show Spent",
            "Budgeted Amounts",
            "Status Filters",
            "Hide Spent Categories",
        ] {
            XCTAssertFalse(
                app.switches[title].exists,
                "\(title) should be available from the Budget tab menu, not Settings"
            )
        }
    }

    @MainActor
    private func tapSwitch(_ toggle: XCUIElement) {
        let control = toggle.switches.firstMatch
        (control.exists ? control : toggle).tap()
    }

    @MainActor
    private func firstBudgetProgressBar(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label MATCHES[c] '.*spent [0-9]+ percent.*'")
        ).firstMatch
    }

    @MainActor
    func testBudgetProgressBarsToggleControlsBudgetRows() {
        let app = launchSettings(showBudgetProgressBars: true)
        openBudgetViewSettings(in: app)

        let toggle = app.switches["Budget Progress Bars"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Budget Progress Bars toggle not found")

        app.tabBars.buttons["Budget"].tap()

        // Demo reseeding resets the viewed month, so the seeded current-month
        // Groceries budget and spending should already produce a progress bar.

        let progressBar = firstBudgetProgressBar(in: app)
        XCTAssertTrue(
            progressBar.waitForExistence(timeout: 10),
            "The demo budget should start with visible category progress bars"
        )

        openBudgetViewSettings(in: app)
        tapSwitch(app.switches["Budget Progress Bars"])
        app.tabBars.buttons["Budget"].tap()
        XCTAssertTrue(
            firstBudgetProgressBar(in: app).waitForNonExistence(timeout: 5),
            "Turning Budget Progress Bars off should remove them from category rows"
        )

        openBudgetViewSettings(in: app)
        tapSwitch(app.switches["Budget Progress Bars"])
        app.tabBars.buttons["Budget"].tap()
        XCTAssertTrue(
            firstBudgetProgressBar(in: app).waitForExistence(timeout: 5),
            "Turning Budget Progress Bars back on should restore them"
        )
    }

    @MainActor
    func testCategoryStatusDotsToggleControlsBudgetRows() {
        let app = launchSettings(showCategoryStatusDots: true)
        openBudgetViewSettings(in: app)

        let toggle = app.switches["Category Status Dots"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Category Status Dots toggle not found")

        let disclosure = app.buttons["Color picker"]
        XCTAssertTrue(
            disclosure.waitForExistence(timeout: 5),
            "Category color picker disclosure not found"
        )
        disclosure.tap()

        let pickerIds = ["unassigned", "funded", "spending", "spent", "overspent"]
        for _ in 0..<5 where pickerIds.contains(where: { stateId in
            !app.descendants(matching: .any)["categoryStatusColorPicker.\(stateId)"].exists
        }) {
            app.swipeUp()
        }
        for stateId in pickerIds {
            let picker = app.descendants(matching: .any)["categoryStatusColorPicker.\(stateId)"]
            XCTAssertTrue(picker.waitForExistence(timeout: 5), "Color picker for \(stateId) not found")
            XCTAssertNotNil(picker.value, "Color picker \(stateId) should expose its selected color")
        }

        let resetButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'categoryStatusColorReset.'")
        )
        XCTAssertEqual(
            resetButtons.count,
            5,
            "All five category status reset controls should be present"
        )

        // The info row sits after the pickers, so the scroll above leaves it
        // on screen.
        let infoButton = app.buttons["Color picker information"]
        XCTAssertTrue(infoButton.waitForExistence(timeout: 5), "Color picker info button not found")
        infoButton.tap()

        let infoAlert = app.alerts["Color picker"]
        XCTAssertTrue(infoAlert.waitForExistence(timeout: 5), "Color picker info alert not found")
        XCTAssertTrue(
            infoAlert.staticTexts["Picked color will be used for both category status dots and progress bars."].exists,
            "Color picker info message not found"
        )
        infoAlert.buttons["OK"].tap()

        for _ in 0..<8 where !disclosure.isHittable {
            app.swipeDown()
        }
        XCTAssertTrue(disclosure.isHittable, "Color picker disclosure should be reachable")
        disclosure.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["categoryStatusColorPicker.overspent"]
                .waitForNonExistence(timeout: 5),
            "Category color pickers should collapse"
        )
        app.tabBars.buttons["Budget"].tap()
        let statusDot = app.descendants(matching: .any)["categoryStatusDot"].firstMatch
        XCTAssertTrue(
            statusDot.waitForExistence(timeout: 10),
            "The demo budget should start with visible category status dots"
        )

        openBudgetViewSettings(in: app)
        let statusDotsAfterReturn = app.switches["Category Status Dots"]
        XCTAssertTrue(
            statusDotsAfterReturn.waitForExistence(timeout: 5),
            "Category Status Dots toggle not found after returning to Settings"
        )
        tapSwitch(statusDotsAfterReturn)
        app.tabBars.buttons["Budget"].tap()
        let statusDotAfterToggle = app.descendants(matching: .any)["categoryStatusDot"].firstMatch
        XCTAssertTrue(
            statusDotAfterToggle.waitForNonExistence(timeout: 5),
            "Turning Category Status Dots off should remove them from category rows"
        )

        openBudgetViewSettings(in: app)
        let statusDotsAfterSecondReturn = app.switches["Category Status Dots"]
        XCTAssertTrue(
            statusDotsAfterSecondReturn.waitForExistence(timeout: 5),
            "Category Status Dots toggle not found when restoring it"
        )
        tapSwitch(statusDotsAfterSecondReturn)
        app.tabBars.buttons["Budget"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["categoryStatusDot"].firstMatch.waitForExistence(timeout: 5),
            "Turning Category Status Dots back on should restore them"
        )
    }
}
