import AppIntents
import Foundation

struct GetPayeesIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Payees"
    static let description = IntentDescription(
        "List all active payees in Actuali.",
        categoryName: "Transactions"
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[PayeeEntity]> & ProvidesDialog {
        let store = BudgetStore.shared
        await store.ensureBudgetReady()

        let payees = await store.payeesForIntent().filter { !$0.tombstone }
        let entities = payees.map { PayeeEntity(id: $0.id, name: $0.name) }

        let dialogText = String(localized: "Found \(entities.count) payees in Actuali.")
        return .result(value: entities, dialog: IntentDialog(stringLiteral: dialogText))
    }
}
