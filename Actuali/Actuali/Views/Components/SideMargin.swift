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
}

extension EnvironmentValues {
    @Entry var sideMargin = CGFloat(SideMargin.standard)
}

private struct SideMarginRoot: ViewModifier {
    @AppStorage(SideMargin.storageKey) private var margin = SideMargin.standard

    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, margin, for: .scrollContent)
            .environment(\.sideMargin, margin)
    }
}

extension View {
    func sideMarginRoot() -> some View {
        modifier(SideMarginRoot())
    }
}
