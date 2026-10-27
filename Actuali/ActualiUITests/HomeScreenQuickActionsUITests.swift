import XCTest

final class HomeScreenQuickActionsUITests: XCTestCase {
    @MainActor
    func testWarmShortcutOpensAddTransaction() throws {
        try assertShortcutOpensAddTransaction(coldLaunch: false)
    }

    @MainActor
    func testColdShortcutOverridesStartPage() throws {
        try assertShortcutOpensAddTransaction(coldLaunch: true)
    }

    @MainActor
    private func assertShortcutOpensAddTransaction(coldLaunch: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", "0"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Accounts"].waitForExistence(timeout: 15))

        // Home Screen launches don't inherit XCUITest's launch arguments.
        // Persist a different Start Page so missing cold-launch routing
        // cannot pass just because Add was already the default.
        let originalStartPage = coldLaunch ? try setStartPage("Budget", in: app) : nil
        defer {
            if let originalStartPage {
                XCTAssertNoThrow(try setStartPage(originalStartPage, in: app))
            }
        }

        app.tabBars.buttons["Accounts"].tap()
        XCTAssertTrue(app.tabBars.buttons["Accounts"].isSelected)
        XCUIDevice.shared.press(.home)
        if coldLaunch {
            app.terminate()
            XCTAssertEqual(app.state, .notRunning)
        }

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icons = springboard.icons.matching(identifier: "Actuali")
        let screen = springboard.frame
        // SpringBoard exposes off-page icons with zero or off-screen frames,
        // and reading an icon attribute mid-animation fails the test outright:
        // isHittable reports "Activation point invalid" while the app zooms back
        // into its icon, and .frame on an element that vanished first reports
        // "No matches found". snapshot() throws instead, so wait for an on-screen
        // frame that holds still across two polls, then press at that frame.
        func settledIconFrame() -> CGRect? {
            var lastFrame: CGRect?
            for _ in 0..<10 {
                let frame = icons.allElementsBoundByIndex
                    .compactMap { (try? $0.snapshot())?.frame }
                    .first { !$0.isEmpty && screen.contains($0) }
                if let frame, frame == lastFrame {
                    return frame
                }
                lastFrame = frame
                Thread.sleep(forTimeInterval: 0.5)
            }
            return nil
        }
        var iconFrame: CGRect?
        for _ in 0..<4 {
            iconFrame = settledIconFrame()
            if iconFrame != nil {
                break
            }
            springboard.swipeLeft()
        }
        guard let iconFrame else {
            XCTFail("Actuali Home Screen icon not reachable: \(springboard.debugDescription)")
            return
        }
        springboard.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: iconFrame.midX, dy: iconFrame.minY + iconFrame.height * 0.4))
            .press(forDuration: 1.2)
        let shortcut = springboard.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Add Transaction")
        ).firstMatch
        XCTAssertTrue(shortcut.waitForExistence(timeout: 5), "Home Screen quick action missing")
        shortcut.tap()

        XCTAssertTrue(app.buttons["addTransaction.payee"].waitForExistence(timeout: 15),
                      "Quick action did not open the transaction form")
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.tabBars.buttons["Add"].isSelected)
    }

    @MainActor
    private func setStartPage(_ page: String, in app: XCUIApplication) throws -> String {
        if app.keyboards.firstMatch.exists {
            app.buttons["Done"].firstMatch.tap()
            if !app.keyboards.firstMatch.waitForNonExistence(timeout: 3) {
                app.buttons["Done"].firstMatch.tap()
            }
            // The tab bar sits behind the keyboard; tapping More before it
            // finishes dismissing lands on the keyboard instead.
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5),
                          "the keyboard stayed up over the tab bar")
        }
        let more = app.tabBars.buttons["More"]
        more.tap()
        if !more.wait(for: \.isSelected, toEqual: true, timeout: 3) {
            more.tap()
        }
        XCTAssertTrue(more.wait(for: \.isSelected, toEqual: true, timeout: 5),
                      "the More tab did not open")
        if !app.navigationBars["Display"].exists {
            let display = app.buttons["Display"]
            for _ in 0..<6 where !display.exists {
                app.swipeUp()
            }
            XCTAssertTrue(display.waitForExistence(timeout: 5),
                          "Display row missing after opening More: \(app.debugDescription)")
            display.tap()
        }
        let picker = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Start Page'")
        ).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let original = try XCTUnwrap(["Accounts", "Budget", "Add Transaction", "Reports"].first {
            picker.label.contains($0)
        })
        picker.tap()
        // The tab bar has buttons with the same labels as these menu items.
        let option = try XCTUnwrap(app.buttons.matching(identifier: page)
            .allElementsBoundByIndex.first { $0.isHittable })
        option.tap()
        XCTAssertTrue(picker.label.contains(page))
        return original
    }
}
