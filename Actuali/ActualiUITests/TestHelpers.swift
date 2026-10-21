import XCTest

extension XCTestCase {
    /// Retry a missed tap only while its expected result is absent, so a
    /// successful toggle cannot be flipped back while its menu dismisses.
    @MainActor
    func tapControl(_ control: XCUIElement, until changed: () -> Bool) {
        let inner = control.switches.firstMatch
        let target = inner.exists ? inner : control
        XCTAssertTrue(target.wait(for: \.isHittable, toEqual: true, timeout: 5))
        for _ in 0..<3 {
            target.tap()
            if changed() {
                return
            }
        }
        XCTFail("Control did not update after tapping \(control.label)")
    }

    /// Open Settings > Budget View whether Settings last showed its hub or
    /// retained the destination from an earlier tab visit.
    @MainActor
    func openBudgetViewSettings(in app: XCUIApplication) {
        app.tabBars.buttons["More"].tap()
        if app.navigationBars["Budget View"].waitForExistence(timeout: 2) {
            return
        }

        let row = app.buttons["Budget View"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Budget View settings row not found")
        row.tap()
        XCTAssertTrue(app.navigationBars["Budget View"].waitForExistence(timeout: 5))
    }

    /// Tap a status chip in the Budget tab's check-in strip.
    ///
    /// The strip scrolls horizontally and holds more chips than fit on a
    /// phone, so a chip can exist while sitting off-screen — `tap()` alone
    /// fails on those. Walk the strip until the chip is reachable.
    @MainActor
    func tapBudgetFilter(_ app: XCUIApplication, _ filter: String) {
        let chip = app.buttons["budgetFilter-\(filter)"]
        XCTAssertTrue(chip.waitForExistence(timeout: 10),
                      "\(filter) filter chip missing from the check-in strip")
        guard !chip.isHittable else {
            chip.tap()
            return
        }
        let strip = app.scrollViews.firstMatch
        for _ in 0..<5 where !chip.isHittable {
            strip.swipeLeft()
        }
        for _ in 0..<10 where !chip.isHittable {
            strip.swipeRight()
        }
        XCTAssertTrue(chip.isHittable, "\(filter) filter chip not reachable in the strip")
        chip.tap()
    }

    /// Scroll the budget table up until `element` can be tapped or pressed.
    ///
    /// Rows below the fold report `isHittable == false`, so `tap()` and
    /// `press(forDuration:)` fail on them without a scroll first.
    @MainActor
    func scrollUntilHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maxSwipes: Int = 12
    ) {
        var swipesLeft = maxSwipes
        while !element.isHittable, swipesLeft > 0 {
            app.swipeUp()
            swipesLeft -= 1
        }
    }

    /// Replace a text field's contents. iOS 27 drops keyboard focus during a
    /// long delete run, and iOS 18 does not select on a double tap, so select
    /// and replace first, then fall back to clearing and retyping.
    @MainActor
    func replaceText(_ text: String, in field: XCUIElement) {
        func holds() -> Bool {
            let value = (field.value as? String) ?? ""
            return text.isEmpty
                ? (value.isEmpty || value == field.placeholderValue)
                : value == text
        }
        field.tap()
        let current = (field.value as? String) ?? ""
        let startsEmpty = current.isEmpty || current == field.placeholderValue
        if !startsEmpty {
            field.tap(withNumberOfTaps: 2, numberOfTouches: 1)
        }
        field.typeText(text.isEmpty ? XCUIKeyboardKey.delete.rawValue : text)
        if !holds() {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30))
            if !text.isEmpty {
                field.typeText(text)
            }
        }
        XCTAssertTrue(holds(), "the field did not receive the new text")
    }

    /// The budget month button's label `offset` months from now, e.g.
    /// "September 2026" — the same "MMMM yyyy" text the app renders.
    func monthTitle(offset: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        let date = Calendar.current.date(byAdding: .month, value: offset, to: Date()) ?? Date()
        return formatter.string(from: date)
    }
}
