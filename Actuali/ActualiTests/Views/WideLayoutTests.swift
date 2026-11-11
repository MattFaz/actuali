import SwiftUI
import Testing
@testable import Actuali

/// The two-pane layouts are the only thing standing between the phone layout
/// and a stretched one on a big display, so the width they turn on at is worth
/// pinning — including the widths that deliberately stay one column.
@Suite("Wide layout")
struct WideLayoutTests {
    @Test("Compact width never splits, however wide the window")
    func compactNeverSplits() {
        #expect(!WideLayout.isWide(sizeClass: .compact, width: 1400))
    }

    @Test("A window with no size class yet stays single-column")
    func missingSizeClassNeverSplits() {
        #expect(!WideLayout.isWide(sizeClass: nil, width: 1400))
    }

    @Test("An iPad needs a full-size window")
    func iPadThreshold() {
        // 11-inch portrait: regular, but too narrow — the sidebar would only
        // be a drawer over the content.
        #expect(!WideLayout.isWide(sizeClass: .regular, width: 834))
        #expect(!WideLayout.isWide(sizeClass: .regular, width: WideLayout.minimumWidth - 1))
        // The boundary itself is wide enough.
        #expect(WideLayout.isWide(sizeClass: .regular, width: WideLayout.minimumWidth))
        // 13-inch portrait and up.
        #expect(WideLayout.isWide(sizeClass: .regular, width: 1024))
    }

    /// Both the width Apple publishes for the inner display (890 pt) and the one
    /// the simulator measures (951 pt) report a regular size class. Below the
    /// threshold the split view turns into an overlay whose sidebar draws over the
    /// detail column and clips its leading text, so both stay single-column.
    @Test("iPhone Duo's inner display stays single-column")
    func duoInnerDisplayStaysSingleColumn() {
        #expect(!WideLayout.isWide(sizeClass: .regular, width: 890))
        #expect(!WideLayout.isWide(sizeClass: .regular, width: 951))
    }
}
