import AppIntents

/// Category choices offered in the widget's edit sheet. Backed by the
/// snapshot the app last wrote — the widget process has no database, so it
/// can only offer what the app has published.
struct WidgetCategoryEntity: AppEntity, Identifiable {
    let id: String
    let name: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Category"

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static let defaultQuery = WidgetCategoryEntityQuery()
}

struct WidgetCategoryEntityQuery: EntityQuery {

    private func allCategories() -> [WidgetCategoryEntity] {
        guard let snapshot = WidgetSnapshotStore.standard()?.read() else { return [] }
        return snapshot.categories.map { WidgetCategoryEntity(id: $0.id, name: $0.name) }
    }

    func entities(for identifiers: [WidgetCategoryEntity.ID]) async throws -> [WidgetCategoryEntity] {
        let byId = Dictionary(allCategories().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { byId[$0] }
    }

    func suggestedEntities() async throws -> [WidgetCategoryEntity] {
        allCategories()
    }
}
