import Foundation
import class SwiftUI.UIHostingController
import Testing
@testable import Actuali

@MainActor
struct CustomReportWidgetLayoutTests {
    private func cardHeight(_ kind: (CustomReportData.Stacked) -> CustomReportData.Kind, series: Int) -> CGFloat {
        let stacked = CustomReportData.Stacked(
            intervalLabels: ["Jan", "Feb", "Mar"],
            seriesNames: (0..<series).map { "Investment account number \($0)" },
            values: Array(repeating: [100, 200, 300], count: series)
        )
        let view = CustomReportWidgetView(data: CustomReportData(name: "Report", rangeLabel: "", kind: kind(stacked)))
            .environmentObject(BudgetStore.previewInstance())
        return UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: 390, height: 2000)).height
    }

    /// The legend used to share the chart's fixed frame, so a long legend
    /// squeezed the plot to nothing and ran past the card. The card has to
    /// grow with the legend instead.
    @Test func longLegendGrowsTheCardInsteadOfSqueezingThePlot() {
        // One series is plot + axis + one legend row, so a card no taller
        // than the 160 pt plot means the plot lost its height.
        #expect(cardHeight({ .stacked($0) }, series: 1) > 160)
        #expect(cardHeight({ .lines($0, trends: []) }, series: 1) > 160)
        #expect(cardHeight({ .stacked($0) }, series: 8) > cardHeight({ .stacked($0) }, series: 1))
        #expect(cardHeight({ .lines($0, trends: []) }, series: 8) > cardHeight({ .lines($0, trends: []) }, series: 1))
    }
}
