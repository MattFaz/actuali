import SwiftUI
import WidgetKit

/// Shared layout for single-metric widgets supporting Home Screen and Lock Screen
/// accessory families (Net Worth, To Be Budgeted).
struct AccessoryAmountView: View {
    @Environment(\.widgetFamily) private var family
    let icon: String
    let label: String
    let value: String?
    let placeholder: String
    let inlineFormat: String
    let color: Color
    let updateDate: Date
    let locale: Locale

    var body: some View {
        switch family {
        case .accessoryCircular:
            circularLayout
        case .accessoryRectangular:
            rectangularLayout
        case .accessoryInline:
            inlineLayout
        default:
            smallLayout
                .containerBackground(.fill.tertiary, for: .widget)
        }
    }

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let value {
                Text(value)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .foregroundStyle(color)
            } else {
                Text(placeholder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(String(
                format: String(localized: "Updated %@", locale: locale),
                WidgetDateFormatting.relative(updateDate, locale: locale)
            ))
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var circularLayout: some View {
        VStack(spacing: 1) {
            Image(systemName: icon)
                .font(.caption)
            if let value {
                Text(value)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
            } else {
                Text("—")
                    .font(.caption)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var rectangularLayout: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let value {
                Text(value)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            } else {
                Text(placeholder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var inlineLayout: some View {
        Group {
            if let value {
                Text(String(format: inlineFormat, value))
            } else {
                Text(String(format: inlineFormat, "—"))
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}
