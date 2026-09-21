import Foundation

/// A managed transaction tag from Actual Budget's `tags` table.
/// Tags in Actual are embedded in transaction notes as `#name`.
/// The `tags` table holds metadata for each tag: color, description, and hidden status.
struct Tag: Identifiable, Equatable, Hashable, Sendable, CRDTSyncable {
    static let datasetName = "tags"

    let id: String
    var tag: String
    var color: String?
    var description: String?
    var hidden: Bool
    var tombstone: Bool

    init(
        id: String = UUID().uuidString,
        tag: String,
        color: String? = nil,
        description: String? = nil,
        hidden: Bool = false,
        tombstone: Bool = false
    ) {
        self.id = id
        self.tag = tag
        self.color = color
        self.description = description
        self.hidden = hidden
        self.tombstone = tombstone
    }

    var displayName: String {
        "#" + tag
    }

    var syncableFields: [String: Any?] {
        [
            "id": id,
            "tag": tag,
            "color": color,
            "description": description,
            "hidden": hidden ? 1 : 0,
            "tombstone": tombstone ? 1 : 0,
        ]
    }

    /// Strips leading `#` and whitespace from a tag name.
    static func normalizeTagName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    }

    /// Validates a tag name: must not be empty, and cannot contain whitespace or `#`.
    static func isValidTagName(_ raw: String) -> Bool {
        let normalized = normalizeTagName(raw)
        return !normalized.isEmpty && !normalized.contains(where: { $0.isWhitespace || $0 == "#" })
    }
}

/// Aggregated usage statistics for a tag across transactions.
struct TagSummary: Identifiable, Equatable, Sendable {
    let tag: Tag
    let transactionCount: Int
    /// Absolute spend in cents (positive value representing expense amount).
    let totalSpent: Int
    /// Net total amount in cents (inflows - outflows).
    let netAmount: Int
    let earliestDate: DayDate?
    let latestDate: DayDate?

    var id: String {
        tag.id
    }
}

import SwiftUI

extension Tag {
    /// Curated palette matching Actual Budget's tag color picker swatches.
    static let presetColors: [String] = [
        "#ef4444", // Red
        "#f97316", // Orange
        "#f59e0b", // Amber
        "#10b981", // Emerald
        "#06b6d4", // Cyan
        "#3b82f6", // Blue
        "#6366f1", // Indigo
        "#8b5cf6", // Purple
        "#ec4899", // Pink
        "#64748b", // Slate
    ]

    /// Resolves the SwiftUI `Color` for this tag, falling back to a theme accent tint.
    var swiftUIColor: Color {
        guard let color, let parsed = Color(hex: color) else {
            return .accentColor
        }
        return parsed
    }
}

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let r, g, b, a: Double
        if hexSanitized.count == 6 {
            r = Double((rgb & 0xff0000) >> 16) / 255.0
            g = Double((rgb & 0x00ff00) >> 8) / 255.0
            b = Double(rgb & 0x0000ff) / 255.0
            a = 1.0
        } else if hexSanitized.count == 8 {
            r = Double((rgb & 0xff000000) >> 24) / 255.0
            g = Double((rgb & 0x00ff0000) >> 16) / 255.0
            b = Double((rgb & 0x0000ff00) >> 8) / 255.0
            a = Double(rgb & 0x000000ff) / 255.0
        } else {
            return nil
        }

        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    func toHex() -> String? {
        guard let components = UIColor(self).cgColor.components, components.count >= 3 else {
            return nil
        }
        let r = Float(components[0])
        let g = Float(components[1])
        let b = Float(components[2])
        return String(format: "#%02lX%02lX%02lX", lroundf(r * 255), lroundf(g * 255), lroundf(b * 255))
    }
}
