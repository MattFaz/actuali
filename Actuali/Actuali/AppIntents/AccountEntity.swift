import AppIntents

struct AccountEntity: AppEntity, Identifiable {
    let id: String
    let name: String

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Account")
    )

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static let defaultQuery = AccountEntityQuery()
}

struct AccountEntityQuery: EntityQuery {

    @MainActor
    func entities(for identifiers: [AccountEntity.ID]) async throws -> [AccountEntity] {
        // Use accountsForIntent() so a cold/headless Shortcut launch can still
        // resolve the saved account before the in-memory cache is populated.
        let accounts = await BudgetStore.shared.accountsForIntent()
        let byId = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        return identifiers.compactMap { id in
            byId[id].map { AccountEntity(id: $0.id, name: $0.name) }
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [AccountEntity] {
        await BudgetStore.shared.accountsForIntent()
            .filter { !$0.closed }
            .map { AccountEntity(id: $0.id, name: $0.name) }
    }
}
