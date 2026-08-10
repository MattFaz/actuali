import AppIntents
import Foundation

struct GetCategoryBalanceIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Category Balance"
    static let description = IntentDescription(
        "Check remaining available budget for a category in Actuali.",
        categoryName: "Budget"
    )
    static let openAppWhenRun = false

    @Parameter(title: "Category")
    var category: CategoryEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get available balance for \(\.$category)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let store = BudgetStore.shared
        await store.ensureBudgetReady()

        guard let categoryBudget = await store.categoryBudgetForIntent(categoryId: category.id) else {
            throw GetBalanceError.categoryNotFound
        }

        let formattedAvailable = store.displayBalance(categoryBudget.available)
        let dialogText = "\(categoryBudget.categoryName) has \(formattedAvailable) available"
        return .result(value: formattedAvailable, dialog: IntentDialog(stringLiteral: dialogText))
    }
}
