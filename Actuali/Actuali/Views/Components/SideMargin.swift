import SwiftUI

/// The side margin of cards and lists, set in Display → Side Margins (GH #748).
/// The root applies it as every scroll view's horizontal content margin, so
/// stock Lists follow it for free; custom surfaces outside a scroll view pad
/// by `\.sideMargin`, and scroll views that lay out their own edges opt out
/// with a zero margin.
enum SideMargin {
    static let storageKey = "listSideMargin"
    /// The margin iOS gives an inset-grouped List.
    static let standard = 20.0
    static let range = 4.0...24.0

    /// Whether this window drops the side margin. A side bar takes it away: the
    /// safe area ends where the bar starts, so a container that draws to the
    /// window edge has nothing left to be inset by. `readableWidth` insets a wide
    /// window's column already, and a phone has no bar, so both keep the margin
    /// the root applied.
    nonisolated static func losesSideMargin(
        sizeClass: UserInterfaceSizeClass?,
        safeArea: WindowInsets
    ) -> Bool {
        sizeClass == .compact && (safeArea.leading > 0 || safeArea.trailing > 0)
    }

    /// The margin a card has to supply itself, on whichever edge the bar takes.
    /// A row background is drawn edge to edge and ignores the content margins the
    /// root sets, so the margin it is given has to be carried by the card. Zero
    /// on a phone, which has no bar, and on a wide window, whose capped column is
    /// already inset.
    nonisolated static func cardMargins(
        sizeClass: UserInterfaceSizeClass?,
        safeArea: WindowInsets,
        margin: CGFloat
    ) -> (leading: CGFloat, trailing: CGFloat) {
        guard losesSideMargin(sizeClass: sizeClass, safeArea: safeArea) else { return (0, 0) }
        return (
            leading: safeArea.leading > 0 ? margin : 0,
            trailing: safeArea.trailing > 0 ? margin : 0
        )
    }

    /// The content margin a `Form` needs: the window's insets plus the user's
    /// margin, per edge — the bar can sit on either side.
    nonisolated static func horizontalMargin(
        safeArea: WindowInsets,
        margin: CGFloat
    ) -> (leading: CGFloat, trailing: CGFloat) {
        (leading: safeArea.leading + margin, trailing: safeArea.trailing + margin)
    }
}

/// The window's horizontal safe area — what a side bar reserves on each edge.
/// Horizontal only: a container padded out of a side bar has no use for the top
/// or bottom edges.
struct WindowInsets: Equatable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
}

extension EnvironmentValues {
    @Entry var sideMargin = CGFloat(SideMargin.standard)
    /// The window's own safe area, published by `ContentView`.
    @Entry var windowHorizontalInsets = WindowInsets()
}

private struct SideMarginRoot: ViewModifier {
    @AppStorage(SideMargin.storageKey) private var margin = SideMargin.standard

    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, margin, for: .scrollContent)
            .environment(\.sideMargin, margin)
    }
}

/// Keeps a `Form` clear of a side bar, which takes 84 pt off the trailing edge
/// on iPhone Duo. Content margins are the lever a `Form` respects — padding the
/// container leaves its rows inside the bar.
///
/// Only where the margin actually goes missing — see `losesSideMargin`. And the
/// insets are the window's, so this belongs on a tab root, not on a `Form` in a
/// sheet, which stops short of the bar but inherits them.
private struct ClearOfSideBar: ViewModifier {
    @Environment(\.sideMargin) private var margin
    @Environment(\.windowHorizontalInsets) private var windowInsets
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        // One tree, always. An `if` here changes view identity, so folding the
        // phone would rebuild everything inside — an Add form would come back
        // empty. Without a bar both edges are the margin the root applies anyway.
        let insets = SideMargin.losesSideMargin(sizeClass: sizeClass, safeArea: windowInsets)
            ? SideMargin.horizontalMargin(safeArea: windowInsets, margin: margin)
            : (leading: margin, trailing: margin)
        return content
            .contentMargins(.leading, insets.leading, for: .scrollContent)
            .contentMargins(.trailing, insets.trailing, for: .scrollContent)
    }
}

extension View {
    func sideMarginRoot() -> some View {
        modifier(SideMarginRoot())
    }

    /// For a `Form` that would otherwise draw its rows under a side bar. Needed
    /// by every tab root that is a Form — the More hub and the Add tab — and by
    /// nothing presented as a sheet.
    func clearOfSideBar() -> some View {
        modifier(ClearOfSideBar())
    }
}
