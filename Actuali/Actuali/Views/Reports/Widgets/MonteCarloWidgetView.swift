import SwiftUI
import Charts

/// Dashboard card for the Monte Carlo retirement simulation. Mirrors
/// upstream MonteCarloCard.tsx: headline success rate to the target age,
/// plus the compact fan chart (p10-p90 band, p25-p75 band, p50 line) from
/// MonteCarloGraph.tsx with axes hidden.
struct MonteCarloWidgetView: View {
    let displayName: String
    let data: MonteCarloData

    // Upstream: Math.round(successRate * 1000) / 10
    private var successPercent: Double {
        (data.successRate * 1000).rounded() / 10
    }

    private var endAge: Double {
        data.currentAge + Double(data.horizonYears)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(displayName).font(.headline)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(successPercent.formatted(.number.precision(.fractionLength(0...1))) + "%")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Text(String(format: String(localized: "Success rate to age %@"), endAge.formatted(.number.precision(.fractionLength(0...1)))))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Chart(data.percentileBands, id: \.year) { band in
                let age = data.currentAge + Double(band.year)
                AreaMark(
                    x: .value("Age", age),
                    yStart: .value("p10", Double(band.p10) / 100.0),
                    yEnd: .value("p90", Double(band.p90) / 100.0)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.purple.opacity(0.15))
                AreaMark(
                    x: .value("Age", age),
                    yStart: .value("p25", Double(band.p25) / 100.0),
                    yEnd: .value("p75", Double(band.p75) / 100.0)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.purple.opacity(0.3))
                LineMark(
                    x: .value("Age", age),
                    y: .value("Median", Double(band.p50) / 100.0)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.purple)
            }
            .chartXScale(domain: data.currentAge...endAge)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 140)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
