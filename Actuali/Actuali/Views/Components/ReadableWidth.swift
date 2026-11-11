import SwiftUI

/// How much window the two-pane layouts (`NavigationSplitView`, the budget
/// inspector, the sidebar tab bar) need before they earn their space.
///
/// `ContentView` measures once; the tabs read the answer off `\.isWideLayout`.
enum WideLayout {
    /// How wide a window has to be before `NavigationSplitView` lays out real
    /// columns instead of collapsing its sidebar into an overlay drawer. 834 pt
    /// (11-inch iPad portrait) is too narrow, 1024 pt (13-inch portrait) works.
    ///
    /// iPhone Duo's inner display lands under it — 951 pt in the simulator,
    /// narrower on the device — where the split view collapses into that same
    /// overlay, drawing the sidebar over the detail column and clipping its
    /// leading text.
    static let minimumWidth: CGFloat = 1000

    nonisolated static func isWide(
        sizeClass: UserInterfaceSizeClass?,
        width: CGFloat
    ) -> Bool {
        guard sizeClass == .regular else { return false }
        return width >= minimumWidth
    }
}

/// iPad and iPhone Duo width adaptations. Every one of these is gated on the
/// horizontal size class being `.regular`, which a phone-width window never
/// reports — the app is portrait-locked on iPhone, so the phone layout is the
/// reference and must not shift by a pixel. A narrow iPad window (Slide Over, a
/// thin Split View pane) reports `.compact` too, and correctly gets the phone
/// layout.
extension EnvironmentValues {
    /// Whether the window is wide enough for genuine side-by-side columns.
    ///
    /// Regular width alone isn't enough: an 11-inch iPad in portrait (834 pt) is
    /// regular, but a `NavigationSplitView` there collapses its sidebar into an
    /// overlay drawer. See `WideLayout`. Set once from the window in
    /// `ContentView`, never from tab content, whose width shrinks when a sidebar
    /// expands — measuring that would let the layout oscillate.
    @Entry var isWideLayout = false
}

extension View {
    /// Caps content width so a phone-shaped list doesn't stretch across 13
    /// inches, centering what's left. `background` paints the gutters either
    /// side: pass the colour the screen's own scroll content sits on, else
    /// the clamped card region floats on the wrong shade.
    ///
    /// A no-op in compact width, and a no-op whenever the container is
    /// already narrower than `maxWidth` (a sidebar-squeezed detail column,
    /// an iPad page sheet), because `maxWidth` only ever shrinks.
    func readableWidth(
        _ maxWidth: CGFloat = 700,
        background: Color = Color(.systemGroupedBackground)
    ) -> some View {
        modifier(ReadableWidth(maxWidth: maxWidth, background: background))
    }
}

private struct ReadableWidth: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let maxWidth: CGFloat
    let background: Color

    func body(content: Content) -> some View {
        if horizontalSizeClass == .regular {
            content
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
                .background(background.ignoresSafeArea())
        } else {
            content
        }
    }
}
