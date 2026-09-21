import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String {
        rawValue
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    func label(locale: Locale, bundle: Bundle = .main) -> String {
        switch self {
        case .system: ReportStrings.text("System", locale: locale, bundle: bundle)
        case .light: ReportStrings.text("Light", locale: locale, bundle: bundle)
        case .dark: ReportStrings.text("Dark", locale: locale, bundle: bundle)
        }
    }
}
