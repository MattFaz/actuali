import XCTest

/// Sync from Bank on a pushed account screen must show its outcome there,
/// not only once the user backs out to the account list (GH #499). The seeded
/// GoCardless link finishes instantly with an explanation, so no bank is needed.
final class BankSyncAlertUITests: XCTestCase {
    @MainActor
    func testSyncFromBankAlertShowsOnAccountScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-seedUnsupportedBankSync"]
        app.launch()

        app.tabBars.buttons["Accounts"].tap()
        let account = app.staticTexts["Chase Checking"].firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 10), "Chase Checking row not found")
        account.tap()

        let moreButton = app.navigationBars.buttons["More"]
        XCTAssertTrue(moreButton.waitForExistence(timeout: 10), "overflow menu not found")
        moreButton.tap()
        let syncButton = app.buttons["Sync from Bank"]
        XCTAssertTrue(syncButton.waitForExistence(timeout: 5), "Sync from Bank not offered")
        syncButton.tap()

        let alert = app.alerts["Bank Sync"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "bank sync alert not shown on the account screen")
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS 'GoCardless'")).firstMatch.exists)
    }
}
