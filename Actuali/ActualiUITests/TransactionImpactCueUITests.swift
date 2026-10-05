import XCTest

/// The balance impact popup (GH #649): changing a categorized transaction
/// shows how its category's available balance moved.
final class TransactionImpactCueUITests: XCTestCase {
    @MainActor
    private func duplicateChipotle(_ app: XCUIApplication) {
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

        let duplicate = app.buttons["Duplicate 1 selected transaction"]
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5))
        duplicate.tap()
    }

    @MainActor
    func testDuplicatingATransactionShowsTheCategoryBalanceImpact() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-transactionDisplayMode", "flat", "-showTransactionImpactCue", "YES"]
        app.launch()
        duplicateChipotle(app)

        let cue = app.descendants(matching: .any)["transactionImpactCue"]
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

        let cue = app.descendants(matching: .any)["transactionImpactCue"]
        XCTAssertFalse(cue.waitForExistence(timeout: 4), "no popup while Show Balance Impact is off")
    }
}
