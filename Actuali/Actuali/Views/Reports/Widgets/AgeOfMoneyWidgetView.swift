import SwiftUI
import Charts

struct AgeOfMoneyWidgetView: View {
    let displayName: String
    let data: AgeOfMoneyData

    private var trendSymbol: (name: String, color: Color)? {
        switch data.trend {
        case .up: return ("arrow.up.right", .green)
        case .down: return ("arrow.down.right", .red)
        case .stable: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(displayName).font(.headline)
                Spacer()
                if let age = data.currentAge {
                    HStack(spacing: 4) {
                        if let trendSymbol {
                            Image(systemName: trendSymbol.name)
                                .foregroundStyle(trendSymbol.color)
                        }
                        Text("\(age) days")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                }
            }

            if data.points.count >= 2 {
                Chart(Array(data.points.enumerated()), id: \.offset) { _, point in
                    AreaMark(
                        x: .value("Month", point.monthLabel),
                        y: .value("Days", point.age)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.linearGradient(
                        colors: [.teal.opacity(0.5), .teal.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    LineMark(
                        x: .value("Month", point.monthLabel),
                        y: .value("Days", point.age)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.teal)
                }
                .frame(height: 140)
            } else {
                Text(data.currentAge == nil ? "Not enough data" : "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            }

            if data.insufficientData {
                Text("Some expenses predate the income history; ages are approximate.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
