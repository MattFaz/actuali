import SwiftUI
import Charts

struct AgeOfMoneyWidgetView: View {
    @Environment(\.locale) private var locale
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
                        Text(ReportStrings.localized("\(age) days", locale: locale))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                }
            }

            if data.points.count >= 2 {
                Chart(Array(data.points.enumerated()), id: \.offset) { _, point in
                    AreaMark(
                        x: .value(ReportStrings.text("Month", locale: locale), point.monthLabel),
                        y: .value(ReportStrings.text("Days", locale: locale), point.age)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.linearGradient(
                        colors: [.teal.opacity(0.5), .teal.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    LineMark(
                        x: .value(ReportStrings.text("Month", locale: locale), point.monthLabel),
                        y: .value(ReportStrings.text("Days", locale: locale), point.age)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.teal)
                }
                .frame(height: 140)
            } else {
                Text(data.currentAge == nil ? ReportStrings.text("Not enough data", locale: locale) : "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            }

            if data.insufficientData {
                Text(ReportStrings.text(
                    "Some expenses predate the income history; ages are approximate.",
                    locale: locale
                ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
