import AppIntents
import Foundation

struct GetCategoriesIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Categories"
    static let description = IntentDescription(
        "List all active budget categories in Actuali.",
        categoryName: "Budget"
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[CategoryEntity]> & ProvidesDialog {
        let store = BudgetStore.shared
        await store.ensureBudgetReady()

        let categories = await store.categoriesForIntent().filter { !$0.hidden }
        let entities = categories.map { CategoryEntity(id: $0.id, name: $0.name) }

        let count = entities.count
        let dialogText = String(format: String(localized: count == 1 ? "Found %lld category in Actuali." : "Found %lld categories in Actuali."), count)
        return .result(value: entities, dialog: IntentDialog(stringLiteral: dialogText))
    }
}
