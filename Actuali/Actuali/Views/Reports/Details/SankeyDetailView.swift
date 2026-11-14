import SwiftUI

extension SankeyData {
    struct DetailRow: Equatable {
        let name: String
        let cents: Int
        let percentageLabel: String
    }

    struct DetailSection: Equatable {
        let layer: SankeyLayer
        let rows: [DetailRow]
    }

    /// Each layer's visible nodes, largest first. A node's amount is what
    /// flows through it: the larger of its inflow and outflow, because the
    /// first layer has no inflow and the last has no outflow.
    var detailSections: [DetailSection] {
        var inflow: [Int: Int] = [:]
        var outflow: [Int: Int] = [:]
        // Layout-scaffolding links carry -1.
        for link in links where link.value > 0 {
            outflow[link.source, default: 0] += link.value
            inflow[link.target, default: 0] += link.value
        }
        return SankeyLayer.allCases.compactMap { layer in
            let rows = nodes.indices
                .filter { nodes[$0].layer == layer && !nodes[$0].isHidden }
                .map { DetailRow(name: nodes[$0].name, cents: max(inflow[$0] ?? 0, outflow[$0] ?? 0),
                                 percentageLabel: nodes[$0].percentageLabel) }
                .filter { $0.cents > 0 }
                .sorted { $0.cents > $1.cents }
            return rows.isEmpty ? nil : DetailSection(layer: layer, rows: rows)
        }
    }
}

extension SankeyLayer {
    var detailTitleKey: String {
        switch self {
        case .incomePayee: "Payees"
        case .incomeCategory: "Income categories"
        case .account: "Accounts"
        case .budget: "Budget"
        case .categoryGroup: "Category groups"
        case .category: "Categories"
        }
    }
}

/// The diagram, then each of its layers as a ranked list: the node labels
/// that have to shrink to 9 pt on the card are readable here.
struct SankeyDetailView: View {
    @EnvironmentObject private var budgetStore: BudgetStore
    @Environment(\.locale) private var locale
    let displayName: String
    let data: SankeyData

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                SankeyWidgetView(displayName: displayName, data: data)
                ForEach(data.detailSections, id: \.layer) { section in
                    self.section(section)
                }
            }
            .padding()
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private func section(_ section: SankeyData.DetailSection) -> some View {
        let largest = Double(section.rows[0].cents)
        return VStack(alignment: .leading, spacing: 0) {
            Text(ReportStrings.text(section.layer.detailTitleKey, locale: locale))
                .font(.headline)
                .padding([.horizontal, .top])
                .padding(.bottom, 8)
            ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.name)
                            .lineLimit(1)
                        Spacer()
                        if data.showPercentages, !row.percentageLabel.isEmpty {
                            Text(row.percentageLabel)
                                .foregroundStyle(.secondary)
                        }
                        Text(budgetStore.displayBalance(row.cents, locale: locale))
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: max(2, geo.size.width * Double(row.cents) / largest))
                    }
                    .frame(height: 5)
                    .accessibilityHidden(true)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("reportDetail.sankey.\(section.layer.rawValue)")
    }
}
