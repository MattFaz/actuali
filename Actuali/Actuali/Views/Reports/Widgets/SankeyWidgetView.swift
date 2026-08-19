import SwiftUI

/// Compact sankey card: layered columns of node bars joined by curved
/// ribbons. Dashboard-tile fidelity — the deterministic top-aligned layout
/// stands in for upstream's d3-style layout; the node/link data is faithful.
struct SankeyWidgetView: View {
    let displayName: String
    let data: SankeyData

    private static let chartHeight: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(displayName).font(.headline)

            if hasDrawableFlows {
                Canvas { context, size in
                    guard let layout = SankeyCardLayout(data: data, size: size) else { return }
                    for ribbon in layout.ribbons {
                        context.fill(ribbon.path, with: .color(ribbon.color.opacity(0.3)))
                    }
                    for bar in layout.bars {
                        context.fill(Path(roundedRect: bar.rect, cornerRadius: 1.5), with: .color(bar.color))
                    }
                    for label in layout.labels {
                        context.draw(
                            Text(label.text).font(.system(size: 9)).foregroundStyle(.secondary),
                            in: label.rect
                        )
                    }
                }
                .frame(height: Self.chartHeight)
            } else {
                Text(String(localized: "No data"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var hasDrawableFlows: Bool {
        data.links.contains { $0.value > 0 }
    }
}

// MARK: - Layout

private struct SankeyCardLayout {
    struct Bar {
        let rect: CGRect
        let color: Color
    }
    struct Ribbon {
        let path: Path
        let color: Color
    }
    struct Label {
        let text: String
        let rect: CGRect
    }

    let bars: [Bar]
    let ribbons: [Ribbon]
    let labels: [Label]

    private static let nodeWidth: CGFloat = 8
    private static let nodeGap: CGFloat = 4
    private static let minLabelHeight: CGFloat = 11
    private static let labelWidth: CGFloat = 76

    init?(data: SankeyData, size: CGSize) {
        let nodeCount = data.nodes.count
        guard nodeCount > 0, size.width > 40, size.height > 20 else { return nil }

        // Node value = max(inflow, outflow) from positive links; hidden
        // scaffolding (-1 links) contributes nothing and stays invisible.
        var inflow = [Int](repeating: 0, count: nodeCount)
        var outflow = [Int](repeating: 0, count: nodeCount)
        for link in data.links where link.value > 0 {
            outflow[link.source] += link.value
            inflow[link.target] += link.value
        }
        let values = (0..<nodeCount).map { max(inflow[$0], outflow[$0]) }

        let visible = (0..<nodeCount).filter { values[$0] > 0 && !data.nodes[$0].isHidden }
        guard !visible.isEmpty else { return nil }

        // Columns: one per layer present, in layer order; nodes keep the
        // engine's (sorted) order within a column.
        let layersPresent = Array(Set(visible.map { data.nodes[$0].layer }))
            .sorted { $0.orderIndex < $1.orderIndex }
        var columnOfLayer: [SankeyLayer: Int] = [:]
        for (index, layer) in layersPresent.enumerated() {
            columnOfLayer[layer] = index
        }
        let columnCount = layersPresent.count
        var columns: [[Int]] = Array(repeating: [], count: columnCount)
        for index in visible {
            columns[columnOfLayer[data.nodes[index].layer]!].append(index)
        }

        let maxColumnTotal = columns.map { column in column.reduce(0) { $0 + values[$1] } }.max() ?? 1
        guard maxColumnTotal > 0 else { return nil }
        let maxGaps = CGFloat((columns.map(\.count).max() ?? 1) - 1) * Self.nodeGap
        let scale = max(size.height - maxGaps, 10) / CGFloat(maxColumnTotal)

        func x(forColumn column: Int) -> CGFloat {
            guard columnCount > 1 else { return (size.width - Self.nodeWidth) / 2 }
            return CGFloat(column) / CGFloat(columnCount - 1) * (size.width - Self.nodeWidth)
        }

        var frames: [Int: CGRect] = [:]
        for (column, nodeIndices) in columns.enumerated() {
            var y: CGFloat = 0
            let barX = x(forColumn: column)
            for index in nodeIndices {
                let height = max(CGFloat(values[index]) * scale, 1.5)
                frames[index] = CGRect(x: barX, y: y, width: Self.nodeWidth, height: height)
                y += height + Self.nodeGap
            }
        }

        var bars: [Bar] = []
        var labels: [Label] = []
        for index in visible {
            guard let rect = frames[index] else { continue }
            let node = data.nodes[index]
            bars.append(Bar(rect: rect, color: Self.color(for: node)))

            // Small labels for the largest nodes only.
            if rect.height >= Self.minLabelHeight, !node.name.isEmpty {
                let text = data.showPercentages && !node.percentageLabel.isEmpty
                    ? "\(node.name) \(node.percentageLabel)"
                    : node.name
                let isLastColumn = columnOfLayer[node.layer] == columnCount - 1
                let labelX = isLastColumn
                    ? rect.minX - Self.labelWidth - 3
                    : rect.maxX + 3
                labels.append(Label(
                    text: text,
                    rect: CGRect(x: labelX, y: rect.midY - 6, width: Self.labelWidth, height: 12)
                ))
            }
        }

        // Ribbons: stacked offsets per node side, in link order.
        var ribbons: [Ribbon] = []
        var sourceOffset = [CGFloat](repeating: 0, count: nodeCount)
        var targetOffset = [CGFloat](repeating: 0, count: nodeCount)
        for link in data.links where link.value > 0 {
            guard let sourceRect = frames[link.source], let targetRect = frames[link.target] else { continue }
            let thickness = CGFloat(link.value) * scale
            let sy = sourceRect.minY + sourceOffset[link.source]
            let ty = targetRect.minY + targetOffset[link.target]
            sourceOffset[link.source] += thickness
            targetOffset[link.target] += thickness

            let x0 = sourceRect.maxX
            let x1 = targetRect.minX
            let midX = (x0 + x1) / 2
            var path = Path()
            path.move(to: CGPoint(x: x0, y: sy))
            path.addCurve(
                to: CGPoint(x: x1, y: ty),
                control1: CGPoint(x: midX, y: sy),
                control2: CGPoint(x: midX, y: ty)
            )
            path.addLine(to: CGPoint(x: x1, y: ty + thickness))
            path.addCurve(
                to: CGPoint(x: x0, y: sy + thickness),
                control1: CGPoint(x: midX, y: ty + thickness),
                control2: CGPoint(x: midX, y: sy + thickness)
            )
            path.closeSubpath()
            ribbons.append(Ribbon(path: path, color: Self.color(for: data.nodes[link.source])))
        }

        self.bars = bars
        self.ribbons = ribbons
        self.labels = labels
    }

    private static let palette: [Color] = [
        .blue, .teal, .indigo, .orange, .purple, .pink, .cyan, .mint
    ]

    private static func color(for node: SankeyData.Node) -> Color {
        if node.isNegative { return .red }
        switch node.key {
        case "to_budget": return .green
        case "budgeted", "available_income", "all_income": return .blue
        case "last_month_overspent": return .red
        case "from_previous_month", "for_next_month": return .gray
        default: break
        }
        if node.key.hasSuffix("__OTHER_BUCKET") { return .gray }
        // Upstream colorIndexFromKey: first 3 hex chars of the (UUID) key as
        // a stable color index.
        let hex = node.key.lowercased().filter { $0.isHexDigit }.prefix(3)
        let value = Int(hex, radix: 16) ?? 0
        return palette[value % palette.count]
    }
}
