import XCTest

/// End-to-end repro for the "tap the log-failure notification → crash" report
/// (NotificationRouter's async delegate methods must complete on the main
/// actor or UIKit's post-response snapshot work aborts the app).
///
/// Launches the app with the DEBUG hook that posts the same failure
/// notification LogTransactionIntent posts, taps the banner — a real
/// system-delivered notification response — and verifies the app survives
/// and shows the prefilled add-transaction sheet.
final class NotificationTapUITests: XCTestCase {

    @MainActor
    func testTappingFailureNotificationOpensPrefillWithoutCrashing() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-postFailureNotification"]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        // Single loop handles both launch states: first run shows the
        // permission alert (tap Allow, then the banner posts); later runs
        // skip straight to the banner. The app stays foreground and
        // willPresent shows the banner over it.
        let bannerQuery = springboard.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'Couldn' OR identifier CONTAINS[c] 'NotificationShortLook' OR identifier CONTAINS[c] 'BannerView'")
        ).firstMatch
        var banner: XCUIElement?
        for _ in 0..<30 {
            let alert = springboard.alerts.firstMatch
            if alert.exists,
               let allowButton = alert.buttons.allElementsBoundByIndex.first(where: { $0.label == "Allow" }) {
                allowButton.tap()
            }
            if bannerQuery.exists {
                banner = bannerQuery
                break
            }
            sleep(2)
        }
        guard let banner else {
            XCTFail("notification banner never appeared. springboard tree:\n\(springboard.debugDescription)")
            return
        }
        banner.tap()

        // The tap delivers userNotificationCenter(_:didReceive:) — the app
        // must survive it.
        sleep(3)
        XCTAssertEqual(app.state, .runningForeground, "app crashed after tapping the notification")

        // And the prefilled sheet should be showing (payee carried through).
        let prefilfledPayee = app.textFields.matching(
            NSPredicate(format: "value == 'Debug Payee'")
        ).firstMatch
        XCTAssertTrue(prefilfledPayee.waitForExistence(timeout: 5),
                      "prefilled add-transaction sheet not shown")
    }

    /// Tapping the "Logged transaction" success notification should land on
    /// the All Accounts transaction list.
    @MainActor
    func testTappingSuccessNotificationOpensAllAccounts() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-postSuccessNotification"]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        let bannerQuery = springboard.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'Logged transaction' OR identifier CONTAINS[c] 'NotificationShortLook' OR identifier CONTAINS[c] 'BannerView'")
        ).firstMatch
        var banner: XCUIElement?
        for _ in 0..<30 {
            let alert = springboard.alerts.firstMatch
            if alert.exists,
               let allowButton = alert.buttons.allElementsBoundByIndex.first(where: { $0.label == "Allow" }) {
                allowButton.tap()
            }
            if bannerQuery.exists {
                banner = bannerQuery
                break
            }
            sleep(2)
        }
        guard let banner else {
            XCTFail("success notification banner never appeared. springboard tree:\n\(springboard.debugDescription)")
            return
        }
        banner.tap()

        sleep(3)
        XCTAssertEqual(app.state, .runningForeground, "app not foreground after tapping the notification")

        XCTAssertTrue(app.navigationBars["All Accounts"].waitForExistence(timeout: 5),
                      "All Accounts list not shown after tapping the success notification")
    }
}
