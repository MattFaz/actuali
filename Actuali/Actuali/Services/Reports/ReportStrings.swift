import Foundation

enum ReportStrings {
    static func localized(
        _ value: String.LocalizationValue,
        locale: Locale? = nil,
        bundle: Bundle = .main
    ) -> String {
        let resolvedLocale = locale ?? .current
        return String(localized: LocalizedStringResource(
            value,
            locale: resolvedLocale,
            bundle: bundle
        ))
    }

    // Bundle(path:) hits disk and runs on every chart label and axis tick, so
    // resolved bundles are cached per parent bundle + language. Keying on the
    // locale identifier keeps a language change resolving to the right bundle.
    private static let bundleCache = FormatterCache<Bundle>()

    static func localizedBundle(for locale: Locale, in bundle: Bundle) -> Bundle {
        bundleCache.value("\(bundle.bundlePath)|\(locale.identifier)") {
            let identifiers = [
                locale.identifier,
                locale.identifier.replacingOccurrences(of: "_", with: "-"),
                locale.language.languageCode?.identifier ?? locale.identifier,
            ]
            var resolved = bundle
            for identifier in identifiers {
                if let path = bundle.path(forResource: identifier, ofType: "lproj"),
                   let localizedBundle = Bundle(path: path) {
                    resolved = localizedBundle
                    break
                }
            }
            return resolved
        }
    }

    static func text(
        _ key: String,
        locale: Locale? = nil,
        bundle: Bundle = .main
    ) -> String {
        let resolvedLocale = locale ?? .current
        return localizedBundle(for: resolvedLocale, in: bundle)
            .localizedString(forKey: key, value: key, table: nil)
    }

    static func format(
        _ key: String,
        _ arguments: any CVarArg...,
        locale: Locale? = nil,
        bundle: Bundle = .main
    ) -> String {
        format(key, arguments: arguments, locale: locale, bundle: bundle)
    }

    static func format(
        _ key: String,
        arguments: [any CVarArg],
        locale: Locale? = nil,
        bundle: Bundle = .main
    ) -> String {
        String(
            format: text(key, locale: locale, bundle: bundle),
            locale: locale ?? .current,
            arguments: arguments
        )
    }

    static func yearsToRetire(
        _ years: Double,
        locale: Locale? = nil,
        bundle: Bundle = .main
    ) -> String {
        let resolvedLocale = locale ?? .current
        return localized("\(years, specifier: "%g") years", locale: resolvedLocale, bundle: bundle)
    }
}
