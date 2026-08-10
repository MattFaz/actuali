import AppIntents

struct PayeeEntity: AppEntity, Identifiable {
    let id: String
    let name: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Payee"

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static let defaultQuery = PayeeEntityQuery()
}

struct PayeeEntityQuery: EntityQuery {

    @MainActor
    func entities(for identifiers: [PayeeEntity.ID]) async throws -> [PayeeEntity] {
        let payees = await BudgetStore.shared.payeesForIntent()
        let byId = Dictionary(uniqueKeysWithValues: payees.map { ($0.id, $0) })
        return identifiers.compactMap { id in
            byId[id].map { PayeeEntity(id: $0.id, name: $0.name) }
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [PayeeEntity] {
        await BudgetStore.shared.payeesForIntent()
            .filter { !$0.tombstone }
            .map { PayeeEntity(id: $0.id, name: $0.name) }
    }
}
