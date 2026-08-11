import AppIntents
import Foundation

/// Opens the app on the add-transaction form with any provided fields
/// pre-filled, instead of logging silently like `LogTransactionIntent` —
/// for automations where details (notes, category) are decided at purchase
/// time and the user wants to review before saving (GH #91).
struct AddTransactionWithReviewIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Transaction with Review"
    static let description = IntentDescription(
        "Open the add-transaction screen with fields pre-filled so you can review and save.",
        categoryName: "Transactions"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Account")
    var account: AccountEntity?

    @Parameter(title: "Card or Account Hint", default: "")
    var cardHint: String

    // String, not Double, for the same reason as LogTransactionIntent:
    // Wallet's amount coerces to 0 as a Number for some cards (issue #41).
    @Parameter(title: "Amount", default: "")
    var amount: String

    @Parameter(title: "Payee", default: "")
    var payee: String

    @Parameter(title: "Notes", default: "")
    var notes: String

    @Parameter(title: "Category")
    var category: CategoryEntity?

    @Parameter(title: "Date")
    var date: Date?

    @Parameter(title: "Is Income", default: false)
    var isIncome: Bool

    @Parameter(title: "Cleared", default: false)
    var cleared: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$amount) at \(\.$payee) in \(\.$account)") {
            \.$cardHint
            \.$notes
            \.$category
            \.$date
            \.$isIncome
            \.$cleared
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = BudgetStore.shared
        // Wait for the budget so account/category resolution below sees data
        // even when the intent cold-starts the app.
        await store.ensureBudgetReady()

        // Resolve the account like LogTransactionIntent: explicit parameter,
        // else card hint. No default-account fallback here — ContentView
        // applies it when presenting the form, and nil degrades gracefully.
        var resolvedAccountId = account?.id
        if resolvedAccountId == nil, !cardHint.isEmpty {
            resolvedAccountId = await store.resolveAccountId(hint: cardHint)
        }

        // Drop a category that no longer exists (deleted since the shortcut
        // was configured) rather than pre-selecting a dangling id the form
        // would happily save.
        var resolvedCategoryId = category?.id
        if let id = resolvedCategoryId {
            let categories = await store.categoriesForIntent()
            if !categories.contains(where: { $0.id == id }) {
                resolvedCategoryId = nil
            }
        }

        NotificationRouter.shared.pendingPrefill = Self.prefill(
            accountId: resolvedAccountId,
            amount: amount,
            payee: payee,
            notes: notes,
            categoryId: resolvedCategoryId,
            date: date ?? Date(),
            isIncome: isIncome,
            cleared: cleared
        )
        return .result()
    }

    /// Pure mapping from intent parameters to the form prefill. The amount is
    /// parsed leniently — the user is about to review the form, so an
    /// unparsable value just leaves the field empty instead of erroring.
    static func prefill(
        accountId: String?,
        amount: String,
        payee: String,
        notes: String,
        categoryId: String?,
        date: Date,
        isIncome: Bool,
        cleared: Bool
    ) -> TransactionPrefill {
        let amountCents = AmountParser.parse(amount).flatMap { parsed in
            parsed.isFinite && parsed > 0 ? Transaction.cents(fromDollars: parsed) : nil
        }
        return TransactionPrefill(
            accountId: accountId,
            payee: payee,
            amountCents: amountCents,
            date: date,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            categoryId: categoryId,
            isIncome: isIncome,
            cleared: cleared
        )
    }
}
