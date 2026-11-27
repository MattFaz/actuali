import SwiftUI

/// What stands in for a drawn chart while a picked range loads, inside
/// `loadingPlaceholder`. Text has the system's redaction; marks drawn by
/// Charts or a Canvas have no placeholder form of their own.
enum ReportSkeleton {
    case bars, line, donut, block
}

extension View {
    /// Swaps a chart for its outline while the page is redacted.
    func loadingSkeleton(_ skeleton: ReportSkeleton) -> some View {
        modifier(ReportSkeletonModifier(skeleton: skeleton))
    }

    /// Marks what a picked range replaces. While that range loads, the
    /// content is redacted under a highlight sweeping left to right, takes
    /// no touches and isn't read out: it still holds the card's numbers.
    func loadingPlaceholder() -> some View {
        modifier(ReportLoadingPlaceholder())
    }
}

private struct ReportSkeletonModifier: ViewModifier {
    @Environment(\.redactionReasons) private var reasons
    let skeleton: ReportSkeleton

    func body(content: Content) -> some View {
        let loading = reasons.contains(.placeholder)
        // Emptied rather than removed, so the page keeps its layout.
        content.opacity(loading ? 0 : 1).overlay {
            if loading {
                ReportSkeletonShape(skeleton: skeleton)
                    .foregroundStyle(Color(.systemFill))
            }
        }
    }
}

private struct ReportSkeletonShape: View {
    let skeleton: ReportSkeleton

    /// A fixed, uneven run, so the outline reads as a chart, not a block.
    private static let heights = [0.45, 0.7, 0.35, 0.55, 0.9, 0.6, 0.75]

    var body: some View {
        switch skeleton {
        case .bars:
            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(Self.heights.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 4)
                            .frame(height: geo.size.height * Self.heights[index])
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        case .line:
            GeometryReader { geo in
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geo.size.height))
                    for (index, height) in Self.heights.enumerated() {
                        path.addLine(to: CGPoint(
                            x: geo.size.width * Double(index) / Double(Self.heights.count - 1),
                            y: geo.size.height * (1 - height)
                        ))
                    }
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                    path.closeSubpath()
                }
            }
        case .donut:
            Circle().strokeBorder(lineWidth: 36)
        case .block:
            RoundedRectangle(cornerRadius: 12)
        }
    }
}

private struct ReportLoadingPlaceholder: ViewModifier {
    @Environment(\.reportRangePending) private var pending
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .redacted(reason: pending ? .placeholder : [])
            .overlay {
                // Reduce Motion keeps the still placeholders.
                if pending, !reduceMotion {
                    // Drawn only where the content drew. Masking the sweep
                    // with the content would build the content twice.
                    ReportShimmerSweep().blendMode(.sourceAtop)
                }
            }
            .compositingGroup()
            .allowsHitTesting(!pending)
            .accessibilityHidden(pending)
    }
}

private struct ReportShimmerSweep: View {
    @State private var swept = false

    var body: some View {
        GeometryReader { geo in
            let band = geo.size.width / 2
            LinearGradient(colors: [.clear, Color.primary.opacity(0.15), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: band)
                .offset(x: swept ? geo.size.width : -band)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { swept = true }
        }
    }
}
