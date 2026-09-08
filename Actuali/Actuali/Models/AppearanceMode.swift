import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var label: String {
        label(locale: .autoupdatingCurrent)
    }

    func label(locale: Locale, bundle: Bundle = .main) -> String {
        switch self {
        case .system: return ReportStrings.text("System", locale: locale, bundle: bundle)
        case .light: return ReportStrings.text("Light", locale: locale, bundle: bundle)
        case .dark: return ReportStrings.text("Dark", locale: locale, bundle: bundle)
        }
    }
}
