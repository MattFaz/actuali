import AppIntents
import Foundation

struct GetAccountsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Accounts"
    static let description = IntentDescription(
        "List all open accounts in Actuali.",
        categoryName: "Accounts"
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[AccountEntity]> & ProvidesDialog {
        let store = BudgetStore.shared
        await store.ensureBudgetReady()

        let accounts = await store.accountsForIntent().filter { !$0.closed }
        let entities = accounts.map { AccountEntity(id: $0.id, name: $0.name) }

        let count = entities.count
        let dialogText = String(localized: "Found \(count) open accounts in Actuali.")
        return .result(value: entities, dialog: IntentDialog(stringLiteral: dialogText))
    }
}
