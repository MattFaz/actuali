import AppIntents
import Foundation

struct CategoryEntity: AppEntity, Identifiable {
    let id: String
    let name: String

    static func scopedID(budgetID: String, categoryID: String) -> String {
        ScopedEntityID.make(budgetID: budgetID, rowID: categoryID)
    }

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Category")
    )

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static let defaultQuery = CategoryEntityQuery()
}

struct CategoryEntityQuery: EntityQuery {
    @IntentParameterDependency<LogTransactionIntent>(\.$budget) var intent

    @MainActor
    private func selectedBudget() async -> (localID: String, scopeID: String)? {
        await BudgetEntity.selection(for: intent?.budget)
    }

    @MainActor
    func entities(for identifiers: [CategoryEntity.ID]) async throws -> [CategoryEntity] {
        let store = BudgetStore.shared
        guard let selection = await selectedBudget() else { return [] }
        let scoped = intent?.budget != nil
        let categories = await store.categoriesForIntent(in: selection.localID)
        let requestedIDs = Set(identifiers.compactMap { identifier in
            ScopedEntityID.rowID(identifier, budgetID: selection.scopeID, allowLegacyID: !scoped)
        })
        return categories.compactMap { category in
            guard requestedIDs.contains(category.id) else { return nil }
            return CategoryEntity(
                id: scoped
                    ? CategoryEntity.scopedID(budgetID: selection.scopeID, categoryID: category.id)
                    : category.id,
                name: category.name
            )
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [CategoryEntity] {
        let store = BudgetStore.shared
        guard let selection = await selectedBudget() else { return [] }
        let scoped = intent?.budget != nil
        return await store.categoriesForIntent(in: selection.localID)
            .filter { !$0.hidden }
            .map { category in
                CategoryEntity(
                    id: scoped
                        ? CategoryEntity.scopedID(budgetID: selection.scopeID, categoryID: category.id)
                        : category.id,
                    name: category.name
                )
            }
    }
}
