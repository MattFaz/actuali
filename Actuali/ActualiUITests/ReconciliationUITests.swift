import XCTest

/// End-to-end coverage for the reconciliation button and the tappable
/// cleared-status dot (actios-8oe7): tapping a row's dot toggles cleared
/// without opening the edit sheet, and the account Reconcile flow locks
/// cleared transactions once the bank balance matches.
final class ReconciliationUITests: XCTestCase {

    @MainActor
    private func openChaseChecking() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()

        app.tabBars.buttons["Accounts"].tap()
        let account = app.staticTexts["Chase Checking"].firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 10))
        account.tap()
        return app
    }

    @MainActor
    func testTappingDotTogglesClearedStatus() throws {
        let app = openChaseChecking()

        // Demo data leaves the newest transactions pending (uncleared).
        let uncleared = app.buttons.matching(
            NSPredicate(format: "label == 'Uncleared'")
        )
        XCTAssertTrue(uncleared.firstMatch.waitForExistence(timeout: 10),
                      "demo data should include pending transactions")
        let before = uncleared.count

        uncleared.firstMatch.tap()

        // The dot flips in place instead of opening the edit sheet.
        let flipped = NSPredicate(format: "count == \(before - 1)")
        expectation(for: flipped, evaluatedWith: uncleared)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.navigationBars["Edit Transaction"].exists,
                       "tapping the dot must not open the edit sheet")
    }

    @MainActor
    func testReconcileLocksClearedTransactions() throws {
        let app = openChaseChecking()

        // Wait for the pushed detail screen (rows + toolbar) to settle.
        let cleared = app.buttons.matching(
            NSPredicate(format: "label == 'Cleared'")
        )
        XCTAssertTrue(cleared.firstMatch.waitForExistence(timeout: 10),
                      "demo data should include cleared transactions")
        XCTAssertEqual(app.buttons.matching(
            NSPredicate(format: "label == 'Reconciled'")
        ).count, 0, "demo data starts with nothing reconciled")

        let reconcileButton = app.buttons["Reconcile"]
        XCTAssertTrue(reconcileButton.waitForExistence(timeout: 10))
        reconcileButton.tap()

        // The bank-balance field prefills with the cleared balance, so the
        // sheet opens in the balances-match state.
        let allReconciled = app.staticTexts["All reconciled!"].firstMatch
        XCTAssertTrue(allReconciled.waitForExistence(timeout: 10))

        app.buttons["Lock Cleared Transactions"].tap()

        // Locking marks every cleared transaction reconciled (blue dot).
        let reconciled = app.buttons.matching(
            NSPredicate(format: "label == 'Reconciled'")
        ).firstMatch
        XCTAssertTrue(reconciled.waitForExistence(timeout: 20),
                      "locking should mark cleared transactions as reconciled")
    }
}
