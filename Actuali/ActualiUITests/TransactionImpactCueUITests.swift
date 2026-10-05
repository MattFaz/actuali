import XCTest

/// The balance impact popup (GH #649): changing a categorized transaction
/// shows how its category's available balance moved.
final class TransactionImpactCueUITests: XCTestCase {
    @MainActor
    private func duplicateChipotle(_ app: XCUIApplication, includeGroceries: Bool = false) {
        app.tabBars.buttons["Accounts"].tap()
        let allAccounts = app.staticTexts["All Accounts"].firstMatch
        XCTAssertTrue(allAccounts.waitForExistence(timeout: 10))
        allAccounts.tap()

        let selectionMode = app.buttons["transactions.selectionMode"]
        XCTAssertTrue(selectionMode.waitForExistence(timeout: 10))
        selectionMode.tap()

        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'transactionRow.' AND label CONTAINS 'Chipotle'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the demo budget has a Chipotle transaction")
        row.tap()

        if includeGroceries {
            let groceries = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH 'transactionRow.' AND label CONTAINS 'Whole Foods'")
            ).firstMatch
            XCTAssertTrue(groceries.waitForExistence(timeout: 10))
            groceries.tap()
        }
        let duplicate = app.buttons[includeGroceries ? "Duplicate 2 selected transactions" : "Duplicate 1 selected transaction"]
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5))
        duplicate.tap()
    }

    @MainActor
    func testDuplicatingATransactionShowsTheCategoryBalanceImpact() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-transactionDisplayMode", "flat", "-showTransactionImpactCue", "YES"]
        app.launch()
        duplicateChipotle(app)

        let cue = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'transactionImpactCue.'")).firstMatch
        XCTAssertTrue(cue.waitForExistence(timeout: 10), "the impact popup appears")
        XCTAssertTrue(cue.label.contains("Dining Out"), "it names the category that moved")
        XCTAssertTrue(cue.label.contains("down"), "a duplicated expense lowers the balance")

        cue.tap()
        XCTAssertTrue(cue.waitForNonExistence(timeout: 5), "tapping dismisses it")
    }

    @MainActor
    func testTheSettingTurnsThePopupOff() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-transactionDisplayMode", "flat", "-showTransactionImpactCue", "NO"]
        app.launch()
        duplicateChipotle(app)

        let cue = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'transactionImpactCue.'")).firstMatch
        XCTAssertFalse(cue.waitForExistence(timeout: 4), "no popup while Show Balance Impact is off")
    }

    @MainActor
    func testMultipleCardsHaveDistinctIdentifiers() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-transactionDisplayMode", "flat", "-showTransactionImpactCue", "YES"]
        app.launch()
        duplicateChipotle(app, includeGroceries: true)
        let cues = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'transactionImpactCue.'"))
        XCTAssertTrue(cues.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(cues.count, 2)
        if cues.count == 2 {
            XCTAssertNotEqual(cues.element(boundBy: 0).identifier, cues.element(boundBy: 1).identifier)
        }
    }
}
