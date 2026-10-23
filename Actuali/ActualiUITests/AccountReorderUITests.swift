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
        app.buttons["accounts.optionsMenu"].tap()
        app.buttons["accountsOptions.reorder"].tap()
        XCTAssertTrue(app.buttons["accounts.reorderDone"].waitForExistence(timeout: 5))

        let chase = app.staticTexts["Chase Checking"].firstMatch
        let appleCard = app.staticTexts["Apple Card"].firstMatch
        let chaseRow = app.cells.containing(.staticText, identifier: "Chase Checking").firstMatch
        let appleCardRow = app.cells.containing(.staticText, identifier: "Apple Card").firstMatch
        XCTAssertTrue(chase.waitForExistence(timeout: 10))
        XCTAssertTrue(chaseRow.exists)
        XCTAssertTrue(appleCardRow.exists)
        XCTAssertLessThan(chase.frame.minY, appleCard.frame.minY)

        // In native List edit mode the reorder handle is at the trailing edge
        // of the source row. Drop in the lower half of the last row so List can
        // resolve the end insertion slot instead of releasing outside the row.
        XCTAssertTrue(chaseRow.isHittable)
        XCTAssertTrue(appleCardRow.isHittable)
        chaseRow.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).press(
            forDuration: 1.0,
            thenDragTo: appleCardRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)),
            withVelocity: .slow,
            thenHoldForDuration: 0
        )

        let movedBelow = NSPredicate { _, _ in chase.frame.minY > appleCard.frame.minY }
        expectation(for: movedBelow, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testDraggingChequingGroupBelowSavingsReordersGroups() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()
        app.tabBars.buttons["Accounts"].tap()
        app.buttons["accounts.optionsMenu"].tap()
        app.buttons["accountsOptions.reorder"].tap()
        XCTAssertTrue(app.buttons["accounts.reorderDone"].waitForExistence(timeout: 5))

        let groupHeaders = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "account.subgroup.")
        )
        let chequing = groupHeaders.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Chequing")
        ).firstMatch
        let savings = groupHeaders.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Savings")
        ).firstMatch
        XCTAssertTrue(chequing.waitForExistence(timeout: 10))
        XCTAssertTrue(savings.waitForExistence(timeout: 10))

        let chequingRow = app.cells.containing(.button, identifier: chequing.identifier).firstMatch
        let allyRow = app.cells.containing(.staticText, identifier: "Ally Savings").firstMatch
        XCTAssertTrue(chequingRow.exists)
        XCTAssertTrue(allyRow.exists)
        XCTAssertTrue(chequingRow.isHittable)
        XCTAssertTrue(allyRow.isHittable)
        XCTAssertLessThan(chequing.frame.minY, savings.frame.minY)

        // Move the group header past the final account of the Savings group.
        chequingRow.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).press(
            forDuration: 1.0,
            thenDragTo: allyRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)),
            withVelocity: .slow,
            thenHoldForDuration: 0
        )

        let groupsReordered = NSPredicate { _, _ in savings.frame.minY < chequing.frame.minY }
        expectation(for: groupsReordered, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
    }
}
