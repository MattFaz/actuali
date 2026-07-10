import AppIntents
import Foundation

/// Errors thrown from `LogTransactionIntent.perform()` that are surfaced to
/// Shortcuts/Wallet automation banners and (via `TransactionLogNotifier`) to
/// local notifications when the silent flow fails.
enum LogTransactionError: Error, LocalizedError, CustomLocalizedStringResourceConvertible {
    case noBudgetLoaded
    case accountUnavailable
    case invalidAmount(received: String)
    case noAmountReceived
    case writeFailed(underlying: String)

    var errorDescription: String? {
        switch self {
        case .noBudgetLoaded:
            return "Open Actuali and select a budget first."
        case .accountUnavailable:
            return "Account is no longer available. Edit your shortcut to pick a different account."
        case .invalidAmount(let received):
            // Show what the automation actually delivered: issue #41 failures
            // hinge on whether iOS passed the real text or a coerced "0".
            let shown = received.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)
            return "Amount must be greater than 0 (received \"\(shown)\")."
        case .noAmountReceived:
            return "No amount was received from the automation. iOS sometimes runs Wallet automations before the transaction details are available."
        case .writeFailed(let underlying):
            return "Couldn't save transaction. Tap to retry. (\(underlying))"
        }
    }

    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: errorDescription ?? "Unknown error")
    }
}
