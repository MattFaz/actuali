import SwiftUI

/// iPad width adaptations. Every one of these is gated on the horizontal size
/// class being `.regular`, which is never true on iPhone — the app is
/// portrait-locked there, so the phone layout is the reference and must not
/// shift by a pixel. A narrow iPad window (Slide Over, a thin Split View
/// pane) reports `.compact` too, and correctly gets the phone layout.
extension EnvironmentValues {
    /// Whether the window is wide enough for genuine side-by-side columns.
    ///
    /// Regular width isn't enough on its own: an 11-inch iPad in portrait
    /// (834 pt) is regular, but a `NavigationSplitView` there collapses its
    /// sidebar into an overlay drawer that slides out under the floating tab
    /// bar — the header ends up behind it, and the tab-sidebar toggle has
    /// nowhere useful to go. At 1024 pt (13-inch portrait) and up the columns
    /// are real and both behave. Set once from the window in `ContentView`,
    /// never from tab content, whose width shrinks when a sidebar expands —
    /// measuring that would let the layout oscillate.
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
