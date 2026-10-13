import XCTest

/// Long-press dragging an account reorders it. Rows move through List's
/// `onMove`; `dropDestination` on a row never fires on iPhone when the drag
/// starts in the same List, which is how this shipped broken once.
final class AccountReorderUITests: XCTestCase {
    @MainActor
    func testDraggingBelowTheLastAccountMovesItToTheEnd() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()
        app.tabBars.buttons["Accounts"].tap()

        let chase = app.staticTexts["Chase Checking"].firstMatch
        let appleCard = app.staticTexts["Apple Card"].firstMatch
        XCTAssertTrue(chase.waitForExistence(timeout: 10))
        XCTAssertLessThan(chase.frame.minY, appleCard.frame.minY)

        chase.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 1.0,
            thenDragTo: appleCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.2)),
            withVelocity: .slow,
            thenHoldForDuration: 1.0
        )

        let movedBelow = NSPredicate { _, _ in chase.frame.minY > appleCard.frame.minY }
        expectation(for: movedBelow, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
    }
}
