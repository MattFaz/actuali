import AppIntents
import Foundation

/// Errors thrown from `LogTransactionIntent.perform()` that are surfaced to
/// Shortcuts/Wallet automation banners and (via `TransactionLogNotifier`) to
/// local notifications when the silent flow fails.
enum LogTransactionError: Error, LocalizedError, CustomLocalizedStringResourceConvertible {
    case noBudgetLoaded
    case noAccountSelected
    case accountUnavailable
    case invalidAmount(received: String)
    case noAmountReceived
    case writeFailed(underlying: String)

    var errorDescription: String? {
        String(localized: localizedStringResource)
    }

    var localizedStringResource: LocalizedStringResource {
        Self.resource(for: self)
    }

    static func localizedString(
        for error: Self,
        locale: Locale,
        bundle: Bundle
    ) -> String {
        String(localized: resource(for: error, locale: locale, bundle: bundle))
    }

    private static func resource(
        for error: Self,
        locale: Locale = .current,
        bundle: Bundle = .main
    ) -> LocalizedStringResource {
        switch error {
        case .noBudgetLoaded:
            return LocalizedStringResource("intent.error.noBudgetLoaded", locale: locale, bundle: bundle)
        case .noAccountSelected:
            return LocalizedStringResource("intent.error.noAccountSelected", locale: locale, bundle: bundle)
        case .accountUnavailable:
            return LocalizedStringResource("intent.error.accountUnavailable", locale: locale, bundle: bundle)
        case .invalidAmount(let received):
            let shown = received.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)
            return LocalizedStringResource("intent.error.invalidAmount \(shown)", locale: locale, bundle: bundle)
        case .noAmountReceived:
            return LocalizedStringResource("intent.error.noAmountReceived", locale: locale, bundle: bundle)
        case .writeFailed(let underlying):
            return LocalizedStringResource("intent.error.writeFailed \(String(describing: underlying))", locale: locale, bundle: bundle)
        }
    }
}

enum GetBalanceError: Error, LocalizedError, CustomLocalizedStringResourceConvertible {
    case accountNotFound
    case categoryNotFound
    case noBudgetLoaded
    case noAccountSelected

    var errorDescription: String? {
        String(localized: localizedStringResource)
    }

    var localizedStringResource: LocalizedStringResource {
        Self.resource(for: self)
    }

    static func localizedString(
        for error: Self,
        locale: Locale,
        bundle: Bundle
    ) -> String {
        String(localized: resource(for: error, locale: locale, bundle: bundle))
    }

    private static func resource(
        for error: Self,
        locale: Locale = .current,
        bundle: Bundle = .main
    ) -> LocalizedStringResource {
        switch error {
        case .accountNotFound:
            return LocalizedStringResource("intent.error.accountNotFound", locale: locale, bundle: bundle)
        case .categoryNotFound:
            return LocalizedStringResource("intent.error.categoryNotFound", locale: locale, bundle: bundle)
        case .noBudgetLoaded:
            return LocalizedStringResource("intent.error.noBudgetLoaded", locale: locale, bundle: bundle)
        case .noAccountSelected:
            return LocalizedStringResource("intent.error.noAccountSelected", locale: locale, bundle: bundle)
        }
    }
}

