import AppIntents

/// Account choices offered in the widget's edit sheet. Backed by the
/// snapshot the app last wrote — the widget process has no database, so it
/// can only offer what the app has published.
struct WidgetAccountEntity: AppEntity, Identifiable {
    let id: String
    let name: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Account"

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static let defaultQuery = WidgetAccountEntityQuery()
}

struct WidgetAccountEntityQuery: EntityQuery {
    private func allAccounts() -> [WidgetAccountEntity] {
        guard let snapshot = WidgetSnapshotStore.standard()?.read(),
              let accounts = snapshot.accounts else { return [] }
        return accounts.map { WidgetAccountEntity(id: $0.id, name: $0.name) }
    }

    func entities(for identifiers: [WidgetAccountEntity.ID]) async throws -> [WidgetAccountEntity] {
        let byId = Dictionary(allAccounts().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return identifiers.compactMap { byId[$0] }
    }

    func suggestedEntities() async throws -> [WidgetAccountEntity] {
        allAccounts()
    }
}
