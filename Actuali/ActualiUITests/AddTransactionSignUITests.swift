import XCTest

/// The amount's sign is the transaction's direction, as in Actual: the
/// keyboard's ± key and the sign beside the amount both flip it.
final class AddTransactionSignUITests: XCTestCase {
    @MainActor
    func testFlipSignKeyAndSignButtonSwitchBetweenExpenseAndIncome() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "2"]
        app.launch()

        let sign = app.buttons["addTransaction.sign"]
        XCTAssertTrue(sign.waitForExistence(timeout: 10))
        XCTAssertEqual(sign.value as? String, "Outflow", "a new transaction starts as an expense")

        // The decimal pad has no minus key; the keyboard bar's ± is the way.
        let flip = app.buttons["Flip sign"]
        XCTAssertTrue(flip.waitForExistence(timeout: 10), "no ± key above the amount keyboard")
        flip.tap()
        XCTAssertEqual(sign.value as? String, "Inflow")

        flip.tap()
        XCTAssertEqual(sign.value as? String, "Outflow")

        // Tapping the sign itself does the same.
        sign.tap()
        XCTAssertEqual(sign.value as? String, "Inflow")
    }
}
