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

    /// The Duo's inner display is 890 pt wide on the hardware and 951 pt in the
    /// simulator, both regular. Below the threshold the split view turns into an
    /// overlay whose sidebar draws over the detail column and clips its leading
    /// text, so the device keeps the single-column layout at both widths.
    @Test("iPhone Duo's inner display stays single-column")
    func duoInnerDisplayStaysSingleColumn() {
        #expect(!WideLayout.isWide(sizeClass: .regular, width: 890))
        #expect(!WideLayout.isWide(sizeClass: .regular, width: 951))
    }
}
