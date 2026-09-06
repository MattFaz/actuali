import AppIntents
import Foundation

/// Parses a shared bank message into transaction fields and queues it in the
/// pending imports inbox for user review. Designed to be called from a
/// Shortcut configured with "Show in Share Sheet" accepting Text.
struct ParseAndQueueTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Import Transaction from Text"
    static let description = IntentDescription(
        LocalizedStringResource("Parse a bank message and queue it for review in Actuali."),
        categoryName: LocalizedStringResource("Transactions")
    )
    static let openAppWhenRun = false

    @Parameter(title: LocalizedStringResource("Message Text"))
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Import transaction from \(\.$text)")
    }

    static func dialogText(
        amount: Double?, payee: String?, locale: Locale, bundle: Bundle = .main
    ) -> String {
        let amountText: String
        if let amount {
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
            amountText = formatter.string(from: NSNumber(value: amount)) ?? "?"
        } else {
            amountText = "?"
        }
        let payeeText = payee ?? String(localized: LocalizedStringResource(
            "Unknown", locale: locale, bundle: bundle))
        return String(localized: LocalizedStringResource(
            "Queued \(amountText) at \(payeeText) for review",
            locale: locale, bundle: bundle))
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let pending = try await Self.queue(
            text: text,
            store: BudgetStore.shared,
            pendingImportStore: PendingImportStore.shared
        )

        let dialogText = Self.dialogText(
            amount: pending.amount,
            payee: pending.payee,
            locale: .autoupdatingCurrent
        )
        return .result(dialog: IntentDialog(stringLiteral: dialogText))
    }

    @MainActor
    static func queue(
        text: String,
        store: BudgetStore,
        pendingImportStore: PendingImportStore
    ) async throws -> PendingImport {
        await store.ensureBudgetReady()

        guard store.currentBudgetId != nil, store.databaseForLogger != nil else {
            throw LogTransactionError.noBudgetLoaded
        }

        let parsed = await TransactionTextParser.parse(text)
        let pending = parsed.toPendingImport(originBudgetId: store.currentBudgetId)
        try pendingImportStore.add(pending)
        return pending
    }
}
