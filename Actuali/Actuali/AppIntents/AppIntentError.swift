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
        switch self {
        case .noBudgetLoaded:
            return String(localized: "intent.error.noBudgetLoaded")
        case .noAccountSelected:
            return String(localized: "intent.error.noAccountSelected")
        case .accountUnavailable:
            return String(localized: "intent.error.accountUnavailable")
        case .invalidAmount(let received):
            // Show what the automation actually delivered: issue #41 failures
            // hinge on whether iOS passed the real text or a coerced "0".
            let shown = received.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)
            return String(
                format: String(localized: "intent.error.invalidAmount %@"),
                String(shown)
            )
        case .noAmountReceived:
            return String(localized: "intent.error.noAmountReceived")
        case .writeFailed(let underlying):
            return String(
                format: String(localized: "intent.error.writeFailed %@"),
                String(describing: underlying)
            )
        }
    }

    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: errorDescription ?? "Unknown error")
    }
}

enum GetBalanceError: Error, LocalizedError, CustomLocalizedStringResourceConvertible {
    case accountNotFound
    case categoryNotFound
    case noBudgetLoaded
    case noAccountSelected

    var errorDescription: String? {
        switch self {
        case .accountNotFound:
            return String(localized: "intent.error.accountNotFound")
        case .categoryNotFound:
            return String(localized: "intent.error.categoryNotFound")
        case .noBudgetLoaded:
            return String(localized: "intent.error.noBudgetLoaded")
        case .noAccountSelected:
            return String(localized: "intent.error.noAccountSelected")
        }
    }

    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: errorDescription ?? "Unknown error")
    }
}

