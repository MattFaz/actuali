import XCTest

/// Cards share one side margin (GH #748): iOS's inset-grouped List margin by
/// default, or whatever Display → Side Margins sets.
final class ListMarginsUITests: XCTestCase {
    @MainActor
    func testCardsShareTheSystemListMargin() {
        let app = launch(margin: "20")
        for (name, insets) in cardInsets(app) {
            XCTAssertEqual(insets.leading, 20, accuracy: 1, "\(name) leading margin")
            XCTAssertEqual(insets.trailing, 20, accuracy: 1, "\(name) trailing margin")
        }
    }

    @MainActor
    func testEveryCardFollowsTheSideMarginSetting() {
        let app = launch(margin: "8")
        let measured = cardInsets(app)

        // A sheet presents outside the tab hierarchy, so check it inherits too.
        app.buttons["addTransaction.category"].tap()
        let sheetCell = app.cells.firstMatch
        XCTAssertTrue(sheetCell.waitForExistence(timeout: 10), "the category picker should open")
        let window = app.windows.firstMatch.frame

        for (name, insets) in measured + [("Category picker", (sheetCell.frame.minX - window.minX,
                                                               window.maxX - sheetCell.frame.maxX))] {
            XCTAssertEqual(insets.0, 8, accuracy: 1, "\(name) leading margin")
            XCTAssertEqual(insets.1, 8, accuracy: 1, "\(name) trailing margin")
        }
    }

    @MainActor
    func testSliderMovesTheMargin() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "4"]
        app.launch()

        app.buttons["Display"].tap()
        let slider = app.sliders["displaySettings.sideMargin"]
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        let card = app.cells.firstMatch
        let window = app.windows.firstMatch.frame

        slider.adjust(toNormalizedSliderPosition: 0)
        XCTAssertEqual(card.frame.minX - window.minX, 4, accuracy: 1, "the slider's low end is 4 pt")

        // 0.8 of 4...24 is the 20 pt default. Restoring it keeps the
        // simulator's persisted defaults clean for every later test.
        slider.adjust(toNormalizedSliderPosition: 0.8)
        XCTAssertEqual(card.frame.minX - window.minX, 20, accuracy: 1, "the default is back")
    }

    /// Forcing the margin through the arguments domain keeps a value persisted
    /// by an earlier run out of the measurement.
    @MainActor
    private func launch(margin: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-listSideMargin", margin,
            "-budgetDisplayStyle", "clean",
            "-showCleanBudgetOverview", "YES",
            "-showBudgetCheckInStrip", "NO",
            "-initialTab", "4",
        ]
        app.launch()
        return app
    }

    /// Leading and trailing insets of a card on More, Accounts, Budget and
    /// Add Transaction, which is visited last because its keyboard covers the
    /// tab bar.
    @MainActor
    private func cardInsets(_ app: XCUIApplication) -> [(String, (leading: CGFloat, trailing: CGFloat))] {
        let window = app.windows.firstMatch
        var result: [(String, (leading: CGFloat, trailing: CGFloat))] = []
        func measure(_ element: XCUIElement, _ name: String) {
            guard element.waitForExistence(timeout: 10) else {
                return XCTFail("\(name) should be visible")
            }
            result.append((name, (element.frame.minX - window.frame.minX,
                                  window.frame.maxX - element.frame.maxX)))
        }
        func topBox(_ id: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: id).firstMatch
        }

        measure(app.cells.firstMatch, "More")
        app.tabBars.buttons["Accounts"].tap()
        measure(topBox("accounts.topBox"), "Accounts summary")
        app.tabBars.buttons["Budget"].tap()
        measure(topBox("budget.topBox"), "Clean budget summary")
        app.tabBars.buttons["Add"].tap()
        measure(app.cells.firstMatch, "Add Transaction")
        return result
    }
}
