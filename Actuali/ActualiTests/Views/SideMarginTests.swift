import SwiftUI
import Testing
@testable import Actuali

/// A `Form` takes its row inset from the content margin it is given, and a window
/// with a side bar reserves 84 pt of its trailing edge — so the margin has to
/// carry that inset or the rows draw under the bar. Measured on the closed Duo:
/// 20 pt from the edge before the fix, 104 pt after.
@Suite("Side margins")
struct SideMarginTests {
    @Test("A side bar's inset is added to the margin, not replaced by it")
    func trailingSideBar() {
        let insets = SideMargin.horizontalMargin(safeArea: WindowInsets(trailing: 84), margin: 20)

        #expect(insets.leading == 20)
        #expect(insets.trailing == 104)
    }

    @Test("The bar can sit on either edge — each one is computed alone")
    func asymmetricInsets() {
        // The bar stays on the camera's physical edge, so a right-to-left layout
        // puts it on the leading side.
        let insets = SideMargin.horizontalMargin(safeArea: WindowInsets(leading: 84), margin: 20)

        #expect(insets.leading == 104)
        #expect(insets.trailing == 20)
    }
}
