import Testing
import UIKit

@testable import Actuali

/// The accent color is the app's global tint, so it lands on top of every
/// standard background. WCAG AA requires 4.5:1 for body-sized text.
private let minimumContrastRatio = 4.5

/// Backgrounds the app actually draws accent-tinted text on: grouped list rows,
/// report cards, and plain screens.
private let contentBackgrounds: [(name: String, color: UIColor)] = [
    ("systemBackground", .systemBackground),
    ("secondarySystemBackground", .secondarySystemBackground),
    ("systemGroupedBackground", .systemGroupedBackground),
    ("secondarySystemGroupedBackground", .secondarySystemGroupedBackground),
    ("tertiarySystemBackground", .tertiarySystemBackground),
]

private func relativeLuminance(of color: UIColor) -> Double {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

    func linearized(_ component: CGFloat) -> Double {
        let value = Double(component)
        return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    return 0.2126 * linearized(red) + 0.7152 * linearized(green) + 0.0722 * linearized(blue)
}

private func contrastRatio(_ first: UIColor, _ second: UIColor) -> Double {
    let lighter = max(relativeLuminance(of: first), relativeLuminance(of: second))
    let darker = min(relativeLuminance(of: first), relativeLuminance(of: second))
    return (lighter + 0.05) / (darker + 0.05)
}

@Suite("Accent color contrast")
struct AccentColorContrastTests {
    private func assertAccentIsReadable(in style: UIUserInterfaceStyle) throws {
        let traits = UITraitCollection(userInterfaceStyle: style)
        let accent = try #require(UIColor(named: "AccentColor")).resolvedColor(with: traits)

        for background in contentBackgrounds {
            let ratio = contrastRatio(accent, background.color.resolvedColor(with: traits))
            #expect(
                ratio >= minimumContrastRatio,
                "Accent on \(background.name) is \(ratio) — needs \(minimumContrastRatio)"
            )
        }
    }

    @Test("Accent text is readable on dark mode backgrounds")
    func darkModeContrast() throws {
        try assertAccentIsReadable(in: .dark)
    }

    @Test("Accent text is readable on light mode backgrounds")
    func lightModeContrast() throws {
        try assertAccentIsReadable(in: .light)
    }
}
