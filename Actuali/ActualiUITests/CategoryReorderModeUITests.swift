import XCTest

/// Reorder mode lives in the Actuali-mark menu. It shows a drag handle on
/// every category and group, and saves the new order when the finger lifts.
final class CategoryReorderModeUITests: XCTestCase {
    @MainActor private func launch(style: String = "clean", hideSpent: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-loadDemoData", "-budgetDisplayStyle", style, "-initialTab", "1",
            "-hideZeroBudgetCategories", hideSpent ? "YES" : "NO",
        ]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Budget"].waitForExistence(timeout: 10))
        return app
    }

    private func handle(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.descendants(matching: .any)["Reorder \(name)"]
    }

    @MainActor private func enterReorderMode(_ app: XCUIApplication) {
        let menu = app.buttons["Actuali menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        // Labels, not identifiers: iOS 27 drops identifiers on menu items.
        let reorder = app.buttons["Reorder Items"]
        if !reorder.waitForExistence(timeout: 5) {
            // The menu occasionally misses the first tap on a cold launch.
            menu.tap()
        }
        XCTAssertTrue(reorder.waitForExistence(timeout: 5), "the Actuali menu offers Reorder Items")
        reorder.tap()
        XCTAssertTrue(handle(app, "Groceries").waitForExistence(timeout: 5), "reorder mode shows a handle on each category")
    }

    @MainActor private func leaveReorderMode(_ app: XCUIApplication) {
        app.buttons["budget.reorderDone"].tap()
        XCTAssertTrue(app.buttons["budget.reorderDone"].waitForNonExistence(timeout: 5), "reorder mode is off")
        XCTAssertFalse(handle(app, "Groceries").exists)
    }

    private func spent(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Transactions for \(name) in")).firstMatch
    }

    @MainActor private func drag(_ from: XCUIElement, to target: XCUIElement, above: Bool = true) {
        let start = from.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.0 : 1.0))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
    }

    @MainActor
    func testReorderModeShowsHandlesAndLeaves() {
        let app = launch()
        XCTAssertFalse(handle(app, "Groceries").exists, "no handles in the normal table")
        enterReorderMode(app)
        XCTAssertTrue(handle(app, "Essentials").exists, "groups have handles too")
        leaveReorderMode(app)
        XCTAssertFalse(handle(app, "Groceries").exists)
    }

    @MainActor
    func testReorderModeIncludesSpentRowsWithoutChangingTheNormalTableFilter() {
        let app = launch(hideSpent: true)
        // Demo rent is paid on the first of the month, leaving zero available.
        XCTAssertTrue(spent(app, "Rent").waitForNonExistence(timeout: 5))
        enterReorderMode(app)
        XCTAssertTrue(handle(app, "Rent").waitForExistence(timeout: 5))
        leaveReorderMode(app)
        XCTAssertTrue(spent(app, "Rent").waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testDraggingACategoryWithinItsGroup() {
        let app = launch()
        enterReorderMode(app)
        drag(handle(app, "Internet"), to: handle(app, "Groceries"))
        sleep(2)
        leaveReorderMode(app)

        XCTAssertLessThan(spent(app, "Internet").frame.minY, spent(app, "Groceries").frame.minY,
                          "Internet should now be above Groceries")
    }

    @MainActor
    func testDraggingACategoryIntoAnotherGroup() {
        let app = launch()
        enterReorderMode(app)
        drag(handle(app, "Internet"), to: handle(app, "Fuel"))
        sleep(2)
        leaveReorderMode(app)

        let transport = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Transport,")).firstMatch
        XCTAssertTrue(transport.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(spent(app, "Internet").frame.minY, transport.frame.minY,
                             "Internet should now sit under Transport")
    }

    @MainActor
    func testDraggingAGroupReordersTheGroups() {
        let app = launch()
        enterReorderMode(app)
        drag(handle(app, "Transport"), to: handle(app, "Essentials"))
        sleep(2)
        leaveReorderMode(app)

        let essentials = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Essentials,")).firstMatch
        let transport = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Transport,")).firstMatch
        XCTAssertTrue(essentials.waitForExistence(timeout: 5) || transport.waitForExistence(timeout: 5))
        XCTAssertLessThan(transport.frame.minY, essentials.frame.minY, "Transport should now come before Essentials")
    }

    @MainActor
    func testReorderingWorksInTheCompactTable() {
        let app = launch(style: "compact")
        enterReorderMode(app)
        drag(handle(app, "Internet"), to: handle(app, "Groceries"))
        sleep(2)
        leaveReorderMode(app)

        let internet = app.staticTexts["Internet"].firstMatch
        let groceries = app.staticTexts["Groceries"].firstMatch
        XCTAssertTrue(internet.waitForExistence(timeout: 5) && groceries.exists)
        XCTAssertLessThan(internet.frame.minY, groceries.frame.minY, "Internet should now be above Groceries in Compact")
    }

    /// Rows below the fold are reached by scrolling, and the lifted row must
    /// still follow the finger there (it used to jump off screen).
    @MainActor
    func testDraggingARowReachedByScrollingStaysUnderTheFinger() {
        let app = launch()
        enterReorderMode(app)
        let gym = handle(app, "Gym")
        for _ in 0..<4 where !gym.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(gym.isHittable, "a row near the bottom is reachable by scrolling")
        let pharmacy = handle(app, "Pharmacy")
        XCTAssertTrue(pharmacy.isHittable)
        XCTAssertLessThan(gym.frame.minY, pharmacy.frame.minY, "Gym starts above Pharmacy")

        drag(pharmacy, to: gym)
        sleep(2)

        XCTAssertLessThan(pharmacy.frame.minY, gym.frame.minY,
                          "Pharmacy should now sit above Gym, wherever the list was scrolled to")
    }

    /// Group headers near the bottom must also stay under the finger.
    @MainActor
    func testDraggingABottomGroupStaysUnderTheFinger() {
        let app = launch()
        enterReorderMode(app)
        for _ in 0..<4 {
            app.swipeUp()
        }
        let handles = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "reorder.groupHandle."))
        // The AX tree can list the same handle twice on iOS 27; without this
        // dedupe `above` and `last` resolve to one element and compare equal
        // however far the drag moved it.
        var seen = Set<String>()
        let visible = (0..<handles.count).map(handles.element(boundBy:))
            .filter { !$0.frame.isEmpty && $0.isHittable && seen.insert($0.identifier).inserted }
            .sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertGreaterThanOrEqual(visible.count, 2, "two group handles are visible at the bottom")
        guard visible.count >= 2, let last = visible.last else { return }
        let above = visible[visible.count - 2]
        let lastId = last.identifier
        // Capture both identifiers before the drag: the elements are
        // index-based queries, so after a reorder `above` can resolve to a
        // different row and compare the moved row with itself.
        let aboveId = above.identifier
        XCTAssertNotEqual(lastId, aboveId, "the two handles must be different groups")
        drag(last, to: above)
        sleep(2)
        // Resolve the on-screen copy, as the dedupe did: the same handle can
        // appear twice and the first copy may be the off-screen one.
        // Identifiers were captured before the drag, and on-screenCopy prefers
        // a hittable copy; after the drop neither row may be hittable, so it
        // falls back to the drawn copy with a real frame.
        guard let moved = onScreenCopy(app.descendants(matching: .any).matching(identifier: lastId)),
              let other = onScreenCopy(app.descendants(matching: .any).matching(identifier: aboveId)) else {
            XCTFail("both group handles stay on screen after the drag")
            return
        }
        XCTAssertLessThan(
            moved.frame.minY, other.frame.minY,
            "the bottom group (\(lastId), y \(moved.frame.minY)) should now sit above "
                + "(\(aboveId), y \(other.frame.minY))"
        )
    }
}
