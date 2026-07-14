import XCTest

/// End-to-end check for the overspent-count badge on the Budget tab (GH #68).
///
/// Demo data has no overspent categories, so the badge must start hidden.
/// Lowering Coffee's budget below its month-to-date spend through the real
/// edit sheet must make a "1" badge appear, the "Overspent Badge" Settings
/// toggle must hide and restore it, and restoring the budget must hide it
/// again.
final class BudgetTabBadgeUITests: XCTestCase {

    @MainActor
    func testBadgeTracksOverspentCategories() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "1"]
        app.launch()

        let budgetTab = app.tabBars.buttons["Budget"]
        XCTAssertTrue(budgetTab.waitForExistence(timeout: 10), "Budget tab not found")

        // Demo data is within budget everywhere: no badge at launch.
        XCTAssertFalse(badgeValue(of: budgetTab).contains("overspent"),
                       "badge value present with no overspent categories: \(budgetTab.debugDescription)")
        attachScreenshot(app, name: "1-no-badge-at-launch")

        // Overspend Coffee by budgeting $1 against ~$19 already spent.
        setBudget(app, category: "Coffee", centsKeystrokes: "100")
        XCTAssertTrue(waitForBadgeValue(of: budgetTab, containing: "1 overspent category"),
                      "badge did not report 1 overspent category. Tab: \(budgetTab.debugDescription)")
        attachScreenshot(app, name: "2-badge-after-overspend")

        // Turning the Settings toggle off must hide the badge even while a
        // category is overspent, and turning it back on must restore it.
        app.tabBars.buttons["Settings"].tap()
        let toggle = app.switches["Overspent Badge"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Overspent Badge toggle not found")
        tapSwitch(toggle)
        XCTAssertTrue(waitForBadgeValue(of: budgetTab, containing: ""),
                      "badge still shown with the setting off: \(budgetTab.debugDescription)")
        attachScreenshot(app, name: "3-badge-hidden-by-setting")
        tapSwitch(toggle)
        XCTAssertTrue(waitForBadgeValue(of: budgetTab, containing: "1 overspent category"),
                      "badge did not return after re-enabling: \(budgetTab.debugDescription)")

        // Restore a healthy budget: badge must disappear again.
        budgetTab.tap()
        setBudget(app, category: "Coffee", centsKeystrokes: "10000")
        XCTAssertTrue(waitForBadgeValue(of: budgetTab, containing: ""),
                      "badge still reported after restoring budget: \(budgetTab.debugDescription)")
        attachScreenshot(app, name: "4-badge-cleared")
    }

    /// Opens the category's edit-budget sheet and types a new amount.
    /// The amount field interprets bare digits as cents ("100" → 1.00).
    @MainActor
    private func setBudget(_ app: XCUIApplication, category: String, centsKeystrokes: String) {
        let editButton = app.buttons["Edit budgeted amount for \(category)"]
        var scrollsLeft = 8
        while !editButton.isHittable && scrollsLeft > 0 {
            app.swipeUp()
            scrollsLeft -= 1
        }
        XCTAssertTrue(editButton.isHittable, "edit button for \(category) not reachable")
        editButton.tap()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "amount field not shown")
        field.tap()
        // Focus select-alls the current value asynchronously; don't rely on
        // that racing in our favor — backspace the old value away instead.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10))
        field.typeText(centsKeystrokes)

        let saveButton = app.buttons["Save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "Save button not shown")
        saveButton.tap()
        // Sheet dismissal returns us to the budget list.
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "edit sheet did not dismiss")
    }

    /// A SwiftUI Toggle row exposes itself as a switch, but taps on the row
    /// don't flip it — the actual control is a nested switch element.
    @MainActor
    private func tapSwitch(_ toggle: XCUIElement) {
        let control = toggle.switches.firstMatch
        (control.exists ? control : toggle).tap()
    }

    /// The numeric badge pill is not itself in the accessibility tree; the
    /// app mirrors it as the tab button's accessibility value.
    @MainActor
    private func badgeValue(of tab: XCUIElement) -> String {
        (tab.value as? String) ?? ""
    }

    @MainActor
    private func waitForBadgeValue(of tab: XCUIElement, containing expected: String,
                                   timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = badgeValue(of: tab)
            if expected.isEmpty ? value.isEmpty : value.contains(expected) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return false
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
