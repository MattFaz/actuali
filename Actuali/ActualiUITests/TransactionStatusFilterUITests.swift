import XCTest
import UIKit

/// End-to-end coverage for the transaction status filter chips (GH #439):
/// chips filter and reset on All Accounts, the menu toggle hides the strip
/// without stranding a filter behind it, and an off-budget account — where
/// the uncategorized chip can never match — never offers it.
final class TransactionStatusFilterUITests: XCTestCase {

    @MainActor
    func testFilterStripSurvivesOnBudgetAccountNavigation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-resetStatusFilterState"]
        app.launch()

        app.tabBars.buttons["Accounts"].tap()
        let allAccounts = app.staticTexts["All Accounts"].firstMatch
        XCTAssertTrue(allAccounts.waitForExistence(timeout: 10))
        allAccounts.tap()
        let allChip = app.buttons["transactionFilter-all"]
        XCTAssertTrue(allChip.waitForExistence(timeout: 10))
        XCTAssertTrue(allChip.isHittable)
        try assertSelectedChipIsRendered(allChip)

        app.navigationBars.buttons.firstMatch.tap()
        let checking = app.staticTexts["Chase Checking"].firstMatch
        XCTAssertTrue(checking.waitForExistence(timeout: 10))
        checking.tap()
        XCTAssertTrue(allChip.waitForExistence(timeout: 10),
                      "status chips should survive navigation to an on-budget account")
        XCTAssertTrue(allChip.isHittable,
                      "status chips should remain visible on an on-budget account")
        try assertSelectedChipIsRendered(allChip)

        app.navigationBars.buttons.firstMatch.tap()
        allAccounts.tap()
        XCTAssertTrue(allChip.waitForExistence(timeout: 10),
                      "status chips should survive returning to All Accounts")
        XCTAssertTrue(allChip.isHittable,
                      "status chips should remain visible after returning to All Accounts")
        try assertSelectedChipIsRendered(allChip)
    }

    @MainActor
    private func assertSelectedChipIsRendered(
        _ chip: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let image = try XCTUnwrap(chip.screenshot().image.cgImage, file: file, line: line)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), file: file, line: line)

        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let channels = pixel.prefix(3).map(Int.init)
        XCTAssertGreaterThan(
            channels.max()! - channels.min()!,
            30,
            "selected status chip should contain its tinted fill",
            file: file,
            line: line
        )
    }

    @MainActor
    func testChipsFilterResetAndHideCleanly() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-resetStatusFilterState"]
        app.launch()

        app.tabBars.buttons["Accounts"].tap()
        let allAccounts = app.staticTexts["All Accounts"].firstMatch
        XCTAssertTrue(allAccounts.waitForExistence(timeout: 10))
        allAccounts.tap()

        let uncategorized = app.buttons["transactionFilter-uncategorized"]
        XCTAssertTrue(uncategorized.waitForExistence(timeout: 10),
                      "status chips should render above All Accounts")

        // Demo transactions all carry categories, so the uncategorized chip
        // empties the list and the empty state offers the way back.
        uncategorized.tap()
        XCTAssertTrue(uncategorized.waitForExistence(timeout: 5) && uncategorized.isSelected,
                      "tapped chip should become selected")
        let emptyState = app.staticTexts["No Matching Transactions"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 10),
                      "uncategorized chip should show the empty state on fully categorized demo data")

        let showAll = app.buttons["Show All Transactions"]
        XCTAssertTrue(showAll.waitForExistence(timeout: 5))
        showAll.tap()
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10),
                      "Show All Transactions should restore the list")

        // Hiding the strip from the menu drops any active filter with it: a
        // chip that isn't visible can't be tapped back to All.
        uncategorized.tap()
        XCTAssertTrue(uncategorized.isSelected)
        let moreButton = app.navigationBars.buttons["More"]
        XCTAssertTrue(moreButton.waitForExistence(timeout: 10))
        let statusFilters = app.buttons["Status Filters"]
        moreButton.tap()
        XCTAssertTrue(statusFilters.waitForExistence(timeout: 5))
        statusFilters.tap()
        // Let the reset's reload land first: the list refilling proves the
        // filter dropped to All, and the absence check then runs against a
        // settled hierarchy instead of one mid-transition.
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 10),
                      "hiding the strip should reset the filter to All")
        XCTAssertFalse(uncategorized.exists,
                       "hiding the strip should remove the chips")

        // Toggling the strip back on proves the reset happened.
        moreButton.tap()
        XCTAssertTrue(statusFilters.waitForExistence(timeout: 5))
        statusFilters.tap()
        let allChip = app.buttons["transactionFilter-all"]
        XCTAssertTrue(allChip.waitForExistence(timeout: 10))
        XCTAssertTrue(allChip.isSelected, "strip should come back filtered to All")
    }

    @MainActor
    func testOffBudgetAccountDropsUncategorizedChipAndCarriesSelection() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-loadDemoData", "-resetStatusFilterState"]
        app.launch()

        app.tabBars.buttons["Accounts"].tap()

        // Select a chip on All Accounts first, so the shared store's
        // selection is non-default before any account view is opened.
        let allAccounts = app.staticTexts["All Accounts"].firstMatch
        XCTAssertTrue(allAccounts.waitForExistence(timeout: 10))
        allAccounts.tap()
        let uncleared = app.buttons["transactionFilter-uncleared"]
        XCTAssertTrue(uncleared.waitForExistence(timeout: 10))
        uncleared.tap()
        XCTAssertTrue(uncleared.isSelected)

        // Back out, then open the off-budget brokerage. Uncategorized can
        // never match there (the filter requires an on-budget account), so
        // the chip must be gone — and the shared selection, which CAN match,
        // must have carried over intact.
        let backButton = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 10))
        backButton.tap()
        let vanguard = app.staticTexts["Vanguard Brokerage"].firstMatch
        XCTAssertTrue(vanguard.waitForExistence(timeout: 10))
        vanguard.tap()

        let carriedUncleared = app.buttons["transactionFilter-uncleared"]
        XCTAssertTrue(carriedUncleared.waitForExistence(timeout: 10),
                      "chips should render on the account view too")
        XCTAssertFalse(app.buttons["transactionFilter-uncategorized"].exists,
                       "off-budget account should not offer the uncategorized chip")
        XCTAssertTrue(carriedUncleared.isSelected,
                      "the shared selection should carry into the account view")
    }
}
