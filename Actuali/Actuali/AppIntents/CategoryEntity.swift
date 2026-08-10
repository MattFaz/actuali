import AppIntents

struct CategoryEntity: AppEntity, Identifiable {
    let id: String
    let name: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Category"

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static let defaultQuery = CategoryEntityQuery()
}

struct CategoryEntityQuery: EntityQuery {

    @MainActor
    func entities(for identifiers: [CategoryEntity.ID]) async throws -> [CategoryEntity] {
        let categories = await BudgetStore.shared.categoriesForIntent()
        let byId = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        return identifiers.compactMap { id in
            byId[id].map { CategoryEntity(id: $0.id, name: $0.name) }
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [CategoryEntity] {
        await BudgetStore.shared.categoriesForIntent()
            .filter { !$0.hidden }
            .map { CategoryEntity(id: $0.id, name: $0.name) }
    }
}
