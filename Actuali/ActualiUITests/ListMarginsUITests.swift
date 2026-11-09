import XCTest

/// Cards keep the side margin iOS gives an inset-grouped List (GH #748).
/// Add Transaction uses the stock List, so it is the reference every other
/// card surface must line up with.
final class ListMarginsUITests: XCTestCase {
    @MainActor
    func testCardsShareTheSystemListMargin() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData",
            "-budgetDisplayStyle", "clean",
            "-showCleanBudgetOverview", "YES",
            "-showBudgetCheckInStrip", "NO",
            "-initialTab", "4",
        ]
        app.launch()

        // Add Transaction is measured last: its keyboard covers the tab bar.
        let window = app.windows.firstMatch
        func insets(_ element: XCUIElement, _ name: String) -> (CGFloat, CGFloat)? {
            guard element.waitForExistence(timeout: 10) else {
                XCTFail("\(name) should be visible")
                return nil
            }
            return (element.frame.minX - window.frame.minX, window.frame.maxX - element.frame.maxX)
        }

        let more = insets(app.cells.firstMatch, "the More menu card")

        app.tabBars.buttons["Accounts"].tap()
        let accounts = insets(
            app.descendants(matching: .any).matching(identifier: "accounts.topBox").firstMatch,
            "the accounts summary"
        )

        app.tabBars.buttons["Budget"].tap()
        let budget = insets(
            app.descendants(matching: .any).matching(identifier: "budget.topBox").firstMatch,
            "the clean budget summary"
        )

        app.tabBars.buttons["Add"].tap()
        guard let reference = insets(app.cells.firstMatch, "the Add Transaction card") else { return }

        for (name, measured) in [("More", more), ("Accounts", accounts), ("Budget", budget)] {
            guard let measured else { continue }
            XCTAssertEqual(measured.0, reference.0, accuracy: 1, "\(name) leading margin")
            XCTAssertEqual(measured.1, reference.1, accuracy: 1, "\(name) trailing margin")
        }
    }
}
