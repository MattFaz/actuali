import AppIntents
import Foundation

struct GetAccountBalanceIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Account Balance"
    static let description = IntentDescription(
        "Check the current balance of an account in Actuali.",
        categoryName: "Accounts"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Account")
    var account: AccountEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get balance for \(\.$account)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let store = BudgetStore.shared
        await store.ensureBudgetReady()

        guard store.currentBudgetId != nil else {
            throw GetBalanceError.noBudgetLoaded
        }

        let resolvedAccountId: String
        if let account {
            resolvedAccountId = account.id
        } else if let defaultId = store.defaultAccountId {
            resolvedAccountId = defaultId
        } else {
            throw GetBalanceError.noAccountSelected
        }

        let accounts = await store.accountsForIntent()
        guard let activeAccount = accounts.first(where: { $0.id == resolvedAccountId && !$0.closed }) else {
            throw GetBalanceError.accountNotFound
        }

        let formattedBalance = store.displayBalance(activeAccount.balance)
        let dialogText = "\(activeAccount.name) balance is \(formattedBalance)"
        return .result(value: formattedBalance, dialog: IntentDialog(stringLiteral: dialogText))
    }
}
