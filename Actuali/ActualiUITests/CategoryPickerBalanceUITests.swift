import XCTest

/// The Add Transaction category picker shows each category's available balance
/// beside its name, as Actua's does.
final class CategoryPickerBalanceUITests: XCTestCase {
    @MainActor
    func testCategoryPickerShowsBalances() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2"]
        app.launch()

        let categoryRow = app.buttons["addTransaction.category"]
        XCTAssertTrue(categoryRow.waitForExistence(timeout: 10))
        categoryRow.tap()

        let balances = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH 'categoryPicker.balance.'")
        )
        XCTAssertTrue(balances.firstMatch.waitForExistence(timeout: 10),
                      "categories should list their balance beside the name")
    }
}
