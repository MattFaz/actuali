import XCTest

/// The All Accounts summary is pinned above the list (GH #679), as the Budget
/// summary is above its table (GH #155): scrolling the accounts must not move
/// it, and it stays tappable.
final class AccountsSummaryPinUITests: XCTestCase {
    @MainActor
    func testSummaryStaysPinnedWhileAccountsScroll() {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData"]
        app.launch()

        app.tabBars.buttons["Accounts"].tap()
        let summary = app.descendants(matching: .any)
            .matching(identifier: "accounts.topBox")
            .firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10),
                      "the accounts summary should be visible")
        // The demo list can fit on a tall phone, so a swipe alone may move
        // nothing: also make sure the summary is no longer a row of the list.
        XCTAssertFalse(app.collectionViews.firstMatch.descendants(matching: .any)
            .matching(identifier: "accounts.topBox").firstMatch.exists,
            "the summary should sit outside the scrolling list")
        let restingY = summary.frame.minY

        app.swipeUp()

        XCTAssertTrue(summary.isHittable,
                      "the pinned summary stays reachable while the list is scrolled")
        XCTAssertEqual(summary.frame.minY, restingY, accuracy: 1,
                       "scrolling the accounts must not move the summary")
    }
}
