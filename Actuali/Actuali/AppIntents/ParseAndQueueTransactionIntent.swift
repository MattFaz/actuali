import AppIntents
import Foundation

/// Parses a shared bank message into transaction fields and queues it in the
/// pending imports inbox for user review. Designed to be called from a
/// Shortcut configured with "Show in Share Sheet" accepting Text.
struct ParseAndQueueTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Import Transaction from Text"
    static let description = IntentDescription(
        "Parse a bank message and queue it for review in Actuali.",
        categoryName: "Transactions"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Message Text")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Import transaction from \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let parsed = await TransactionTextParser.parse(text)
        let pending = parsed.toPendingImport()
        PendingImportStore.shared.add(pending)

        let payeeText = parsed.payee ?? "unknown"
        let amountText = parsed.amount.map { String(format: "%.2f", $0) } ?? "?"
        return .result(dialog: "Queued \(amountText) at \(payeeText) for review")
    }
}
