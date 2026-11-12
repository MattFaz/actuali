import SwiftUI
import Testing
@testable import Actuali

/// A side bar reserves 84 pt of the window's trailing edge, and the containers
/// that draw to that edge — a `Form`, a row's card — take their inset from the
/// margin they are given, so that margin has to carry the inset. On the closed
/// Duo that puts them 104 pt from the edge: the bar's 84 plus the 20 pt margin.
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

    @Test("A compact window with a side bar loses the margin")
    func compactWithSideBar() {
        // iPhone Duo, closed.
        #expect(SideMargin.losesSideMargin(sizeClass: .compact, safeArea: WindowInsets(trailing: 84)))
        #expect(SideMargin.losesSideMargin(sizeClass: .compact, safeArea: WindowInsets(leading: 84)))
    }

    @Test("A card takes the margin only on the edge the bar is on")
    func cardMarginsFollowTheBar() {
        let trailing = SideMargin.cardMargins(
            sizeClass: .compact, safeArea: WindowInsets(trailing: 84), margin: 20
        )
        #expect(trailing.leading == 0)
        #expect(trailing.trailing == 20)

        // In a right-to-left locale the bar moves to the leading edge, and the
        // card has to follow it there.
        let leading = SideMargin.cardMargins(
            sizeClass: .compact, safeArea: WindowInsets(leading: 84), margin: 20
        )
        #expect(leading.leading == 20)
        #expect(leading.trailing == 0)
    }

    @Test("A card takes no margin where the root's margins still apply")
    func cardMarginsStandDown() {
        #expect(SideMargin.cardMargins(
            sizeClass: .compact, safeArea: WindowInsets(), margin: 20
        ) == (0, 0))
        #expect(SideMargin.cardMargins(
            sizeClass: .regular, safeArea: WindowInsets(trailing: 84), margin: 20
        ) == (0, 0))
    }

    @Test("A phone keeps it — there is no bar to take it")
    func compactWithoutSideBar() {
        #expect(!SideMargin.losesSideMargin(sizeClass: .compact, safeArea: WindowInsets()))
    }

    @Test("A wide window keeps it — readableWidth already insets the column")
    func regularWithSideBar() {
        // iPhone Duo, unfolded: the bar is there, but the content sits in a capped
        // column that is already clear of it.
        #expect(!SideMargin.losesSideMargin(sizeClass: .regular, safeArea: WindowInsets(trailing: 84)))
    }
}
