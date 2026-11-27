import SwiftUI

/// Lays its children out left to right and wraps to a new line when the row
/// is full, centering each line's children vertically. Oversized text wraps within
/// the available width; single-line chips truncate.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    private struct InlineSeparatorKey: LayoutValueKey {
        static let defaultValue = false
    }

    /// A separator is only visible when the adjacent items share a line.
    struct InlineSeparator: View {
        var body: some View {
            Text(verbatim: "•")
                .font(.caption)
                .foregroundStyle(Color.secondary.opacity(0.8))
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .clipped()
                .accessibilityHidden(true)
                .layoutValue(key: InlineSeparatorKey.self, value: true)
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func size(of subview: LayoutSubviews.Element, in width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard ideal.width > width else { return ideal }
        let constrained = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: constrained.height)
    }

    private func lines(for width: CGFloat, _ subviews: Subviews) -> [Line] {
        var lines = [Line()]
        for (index, subview) in subviews.enumerated() {
            let size = size(of: subview, in: width)
            if subview[InlineSeparatorKey.self] {
                guard let last = lines.last, !last.indices.isEmpty, index + 1 < subviews.count else { continue }
                let next = self.size(of: subviews[index + 1], in: width)
                if last.width + spacing * 2 + size.width + next.width > width {
                    // Wrap at the field boundary instead of leaving a bullet
                    // dangling at either edge of a line.
                    lines.append(Line())
                    continue
                }
            }
            if let last = lines.last, !last.indices.isEmpty, last.width + spacing + size.width > width {
                lines.append(Line())
            }
            let gap = lines[lines.count - 1].indices.isEmpty ? 0 : spacing
            lines[lines.count - 1].indices.append(index)
            lines[lines.count - 1].width += gap + size.width
            lines[lines.count - 1].height = max(lines[lines.count - 1].height, size.height)
        }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let lines = lines(for: proposal.width ?? .infinity, subviews)
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: min(lines.map(\.width).max() ?? 0, proposal.width ?? .infinity), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let lines = lines(for: bounds.width, subviews)
        let placed = Set(lines.flatMap(\.indices))
        // SwiftUI may otherwise place omitted subviews at its default position.
        for index in subviews.indices where !placed.contains(index) {
            subviews[index].place(at: bounds.origin, proposal: .zero)
        }

        var y = bounds.minY
        for line in lines {
            var x = bounds.minX
            for index in line.indices {
                let size = size(of: subviews[index], in: bounds.width)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }
}
