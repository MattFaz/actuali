import SwiftUI
import WidgetKit

extension WidgetFamily {
    /// The home screen families, plus `extra`, then Extra Large Portrait
    /// where the OS has it.
    static func systemFamilies(adding extra: [WidgetFamily] = []) -> [WidgetFamily] {
        let base: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge] + extra
        if #available(iOS 27.0, *) {
            return base + [.systemExtraLargePortrait]
        }
        return base
    }

    /// `systemExtraLargePortrait` is iOS 27-only, so it's matched behind
    /// `#available` rather than a `switch` case.
    var isExtraLargePortrait: Bool {
        if #available(iOS 27.0, *) {
            return self == .systemExtraLargePortrait
        }
        return false
    }

    /// Large or Extra Large Portrait, the families that show full lists.
    var isLarge: Bool {
        self == .systemLarge || isExtraLargePortrait
    }
}

extension WidgetRowLimits {
    /// The row count for `family`; accessory families list nothing.
    func rows(for family: WidgetFamily) -> Int {
        if family.isExtraLargePortrait {
            return extraLargePortrait
        }
        return switch family {
        case .systemSmall: small
        case .systemMedium: medium
        case .systemLarge: large
        default: 0
        }
    }
}

/// The "Updated 5 minutes ago" line at the foot of every widget.
struct WidgetUpdatedFooter: View {
    @Environment(\.locale) private var locale

    let date: Date

    var body: some View {
        Text(String(
            format: String(localized: "Updated %@", locale: locale),
            WidgetDateFormatting.relative(date, locale: locale)
        ))
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}
