import UIKit
import XCTest

/// Coverage for the iPad-only layouts. Skipped on iPhone, which keeps the
/// compact tab-bar-and-push layout these assertions would contradict.
final class IPadSplitLayoutUITests: XCTestCase {

    /// Matches `ContentView.wideLayoutThreshold`: below it the iPad falls back
    /// to the phone's push navigation, so an 11-inch portrait simulator skips
    /// the split-view tests. Run them on a 13-inch, or in landscape.
    private let wideLayoutThreshold: CGFloat = 1000

    /// Skip before launching, not after: on a phone every test here ends in a
    /// skip anyway, and paying for four app launches to learn that is what
    /// times them out ("Timed out while launching application via Xcode") on a
    /// loaded runner. A retry that skips doesn't clear the first run's failure,
    /// so the suite fails the job.
    @MainActor
    private func launch(initialTab: Int) throws -> XCUIApplication {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad,
                          "iPad-only layouts; this device is a phone")
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-initialTab", String(initialTab)]
        app.launch()
        return app
    }

    @MainActor
    private func launchWide(initialTab: Int) throws -> XCUIApplication {
        let app = try launch(initialTab: initialTab)
        try XCTSkipUnless(
            app.windows.firstMatch.frame.width >= wideLayoutThreshold,
            "split layouts only; this window is too narrow for side-by-side columns"
        )
        return app
    }

    /// The Accounts tab shows its list beside the transactions rather than
    /// pushing to them, and All Accounts is selected out of the gate so the
    /// detail column is never empty.
    @MainActor
    func testAccountsOpenBesideTheListInsteadOfPushing() throws {
        let app = try launchWide(initialTab: 0)

        XCTAssertTrue(app.navigationBars["All Accounts"].waitForExistence(timeout: 15),
                      "detail column should start on All Accounts")
        // Both columns on screen at once: the sidebar's own title survives
        // alongside the detail's.
        XCTAssertTrue(app.navigationBars["Accounts"].exists,
                      "sidebar should stay visible beside the detail")

        // Selecting an account swaps the detail column in place.
        let account = app.staticTexts["Chase Checking"].firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 10))
        account.tap()

        XCTAssertTrue(app.navigationBars["Chase Checking"].waitForExistence(timeout: 10),
                      "tapping an account should load it into the detail column")
        XCTAssertTrue(app.navigationBars["Accounts"].exists,
                      "the sidebar should still be there after selecting")
    }

    /// The detail column's rows follow the selection, not just its title: the
    /// split layout reuses one `AccountDetailView`, and its paged transactions
    /// used to be keyed to the account it was first built for — leaving the
    /// previous account's rows under the new one's name and balance.
    @MainActor
    func testSelectingAnotherAccountReloadsItsTransactions() throws {
        let app = try launchWide(initialTab: 0)

        let chase = app.staticTexts["Chase Checking"].firstMatch
        XCTAssertTrue(chase.waitForExistence(timeout: 15))
        chase.tap()

        // Payees unique to each account's demo transactions.
        let chasePayee = app.staticTexts["Whole Foods"].firstMatch
        XCTAssertTrue(chasePayee.waitForExistence(timeout: 10),
                      "Chase's own transactions should load")

        app.staticTexts["Apple Card"].firstMatch.tap()

        let cardPayee = app.staticTexts["Blue Bottle Coffee"].firstMatch
        XCTAssertTrue(cardPayee.waitForExistence(timeout: 10),
                      "the newly selected account's transactions should load")
        // The sidebar keeps both account names on screen, so assert on a payee
        // that only the previous account had.
        XCTAssertFalse(app.staticTexts["Whole Foods"].exists,
                       "the previous account's rows should be gone")
    }

    /// The layout follows the window, not the device: an 11-inch iPad is too
    /// narrow for columns in portrait and wide enough in landscape, and gets
    /// the phone's push navigation in the former (where the split view's
    /// sidebar would otherwise open as a drawer under the floating tab bar).
    @MainActor
    func testRotatingIntoLandscapeBringsUpTheSplitLayout() throws {
        let app = try launch(initialTab: 0)

        XCTAssertTrue(app.staticTexts["Chase Checking"].waitForExistence(timeout: 15))
        let portraitWidth = app.windows.firstMatch.frame.width

        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }

        let landscapeWidth = app.windows.firstMatch.frame.width
        try XCTSkipUnless(landscapeWidth > portraitWidth,
                          "orientation is locked here; nothing to check")
        try XCTSkipUnless(landscapeWidth >= wideLayoutThreshold,
                          "still too narrow for side-by-side columns in landscape")

        XCTAssertTrue(app.navigationBars["All Accounts"].waitForExistence(timeout: 10),
                      "landscape should put the detail column beside the list")
        XCTAssertTrue(app.navigationBars["Accounts"].exists,
                      "the account list should stay on screen as a sidebar")
    }

    /// Regular width caps content width rather than stretching phone-shaped
    /// rows edge to edge: the budget table stays narrower than the window.
    @MainActor
    func testBudgetTableIsWidthCapped() throws {
        // Launched straight onto the tab: in the sidebar layout the tab
        // controls aren't the tab-bar buttons the phone tests tap.
        let app = try launch(initialTab: 1)
        // Capping applies at any regular width, not just wide enough for
        // columns — it just needs a window wider than the 700 pt cap.
        try XCTSkipUnless(app.windows.firstMatch.frame.width > 760,
                          "nothing to cap; this window is narrower than the cap")

        let groceries = app.buttons["Details for Groceries"].firstMatch
        XCTAssertTrue(groceries.waitForExistence(timeout: 15), "budget rows should load")

        let windowWidth = app.windows.firstMatch.frame.width
        // The row's amount button sits at the table's trailing edge; if the
        // table were full-bleed it would land within a hair of the window's.
        let amount = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Edit budgeted amount for Groceries'")
        ).firstMatch
        XCTAssertTrue(amount.waitForExistence(timeout: 10))
        XCTAssertLessThan(amount.frame.maxX, windowWidth - 40,
                          "budget table should be capped, not stretched to the window edge")
    }
}
