import AppIntents
import Foundation

/// A budget that can be targeted by a shortcut. Synced budgets use their stable
/// server file ID; local-only budgets use the local metadata ID.
struct BudgetEntity: AppEntity, Identifiable {
    let id: String
    let name: String

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Budget")
    )

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static let defaultQuery = BudgetEntityQuery()

    static func canWriteToLocally(_ metadata: BudgetMetadata) -> Bool {
        metadata.canWriteToLocally
    }

    @MainActor
    static func availableEntities(
        localBudgets: [BudgetMetadata],
        remoteBudgets: [BudgetStore.RemoteBudget],
        isConnected: Bool
    ) -> [BudgetEntity] {
        let remoteByID = Dictionary(
            remoteBudgets.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let detachedCloudFileIDs = Set(
            localBudgets.filter { !$0.canWriteToLocally }.compactMap(\.cloudFileId)
        )
        var entities: [String: BudgetEntity] = [:]

        for metadata in localBudgets.sorted(by: { $0.id < $1.id })
            where canWriteToLocally(metadata) {
            if isConnected, metadata.id == DemoDataSeeder.budgetId {
                continue
            }
            if isConnected, metadata.cloudFileId == DemoDataSeeder.budgetId {
                continue
            }
            let fileID = metadata.cloudFileId ?? metadata.id
            let identity = metadata.cloudFileId.map { "cloud:\($0)" } ?? "local:\(metadata.id)"
            entities[identity] = BudgetEntity(
                id: fileID,
                name: remoteByID[fileID]?.name ?? metadata.budgetName ?? String(localized: "Budget")
            )
        }

        if isConnected {
            for remote in remoteBudgets.sorted(by: {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }) where remote.groupId?.isEmpty == false
                && remote.id != DemoDataSeeder.budgetId
                && !detachedCloudFileIDs.contains(remote.id) {
                entities["cloud:\(remote.id)"] = BudgetEntity(id: remote.id, name: remote.name)
            }
        }

        return entities.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

struct BudgetEntityQuery: EntityQuery {
    @MainActor
    private func available(fetchRemote: Bool = true) async -> (
        entities: [BudgetEntity],
        localBudgets: [BudgetMetadata],
        isConnected: Bool
    ) {
        let store = BudgetStore.shared
        await store.ensureSavedSessionReady()
        // Saved shortcuts resolve from disk; only discovery or missing IDs
        // require a network request.
        if fetchRemote, store.isConnected {
            await store.fetchRemoteBudgets()
        }

        let fileManager = BudgetFileManager.shared
        let localBudgets = fileManager.listLocalBudgets()
            .filter { fileManager.budgetExists($0.id) }
        let entities = BudgetEntity.availableEntities(
            localBudgets: localBudgets,
            remoteBudgets: store.isConnected ? store.remoteBudgets : [],
            isConnected: store.isConnected
        )
        return (entities, localBudgets, store.isConnected)
    }

    @MainActor
    static func needsRemoteFetch(
        identifiers: [BudgetEntity.ID],
        entities: [BudgetEntity],
        localBudgets: [BudgetMetadata],
        isConnected: Bool
    ) -> Bool {
        guard isConnected else { return false }
        return identifiers.contains { identifier in
            !entities.contains(where: { $0.id == identifier })
                && !localBudgets.contains(where: { $0.id == identifier })
        }
    }

    @MainActor
    func entities(for identifiers: [BudgetEntity.ID]) async throws -> [BudgetEntity] {
        var result = await available(fetchRemote: false)
        if Self.needsRemoteFetch(
            identifiers: identifiers,
            entities: result.entities,
            localBudgets: result.localBudgets,
            isConnected: result.isConnected
        ) {
            result = await available()
        }
        var seen = Set<String>()
        var entities: [BudgetEntity] = []

        for identifier in identifiers {
            if let entity = result.entities.first(where: { $0.id == identifier }) {
                if seen.insert(entity.id).inserted {
                    entities.append(entity)
                }
                continue
            }

            // Previously saved shortcuts used local metadata IDs for synced budgets.
            guard let local = result.localBudgets.first(where: { $0.id == identifier }),
                  BudgetEntity.canWriteToLocally(local),
                  !(result.isConnected && local.id == DemoDataSeeder.budgetId),
                  let entity = result.entities.first(where: {
                      $0.id == (local.cloudFileId ?? local.id)
                  }),
                  seen.insert(entity.id).inserted
            else { continue }
            entities.append(BudgetEntity(id: identifier, name: entity.name))
        }
        return entities
    }

    @MainActor
    func suggestedEntities() async throws -> [BudgetEntity] {
        await available().entities
    }
}

/// A row identifier is scoped to the selected cloud budget (or its local file ID).
/// Legacy IDs are accepted only when no budget parameter was supplied.
enum ScopedEntityID {
    private static let separator = "|"

    static func make(budgetID: String, rowID: String) -> String {
        "\(budgetID)\(separator)\(rowID)"
    }

    static func rowID(
        _ entityID: String,
        entityBudgetID: String,
        localBudgetID: String,
        allowLegacyID: Bool
    ) -> String? {
        if let range = entityID.range(of: separator) {
            let prefix = String(entityID[..<range.lowerBound])
            guard prefix == entityBudgetID || prefix == localBudgetID else { return nil }
            return String(entityID[range.upperBound...])
        }
        return allowLegacyID ? entityID : nil
    }
}

struct AccountEntity: AppEntity, Identifiable {
    let id: String
    let name: String

    static func scopedID(budgetID: String, accountID: String) -> String {
        ScopedEntityID.make(budgetID: budgetID, rowID: accountID)
    }

    static func accountID(
        from entityID: String,
        budgetID: String,
        allowLegacyID: Bool
    ) -> String? {
        ScopedEntityID.rowID(
            entityID, entityBudgetID: budgetID, localBudgetID: budgetID,
            allowLegacyID: allowLegacyID
        )
    }

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Account")
    )

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static let defaultQuery = AccountEntityQuery()
}

struct AccountEntityQuery: EntityQuery {
    @IntentParameterDependency<LogTransactionIntent>(\.$budget) var intent

    @MainActor
    private func selectedBudget() async -> (localID: String, scopeID: String)? {
        let store = BudgetStore.shared
        if let selectedBudget = intent?.budget {
            guard let localID = try? await store.localBudgetIDForIntent(selectedBudget.id) else {
                return nil
            }
            return (localID, selectedBudget.id)
        }
        guard !(store.isConnected && store.currentBudgetId == DemoDataSeeder.budgetId),
              let currentBudgetID = store.currentBudgetId else {
            return nil
        }
        return (currentBudgetID, currentBudgetID)
    }

    @MainActor
    func entities(for identifiers: [AccountEntity.ID]) async throws -> [AccountEntity] {
        let store = BudgetStore.shared
        guard let selection = await selectedBudget() else { return [] }
        let scoped = intent?.budget != nil
        let accounts = await store.accountsForIntent(in: selection.localID)
        let requestedIDs = Set(identifiers.compactMap { identifier in
            ScopedEntityID.rowID(
                identifier, entityBudgetID: selection.scopeID,
                localBudgetID: selection.localID, allowLegacyID: !scoped
            )
        })
        return accounts.compactMap { account in
            guard requestedIDs.contains(account.id) else { return nil }
            return AccountEntity(
                id: scoped
                    ? AccountEntity.scopedID(budgetID: selection.scopeID, accountID: account.id)
                    : account.id,
                name: account.name
            )
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [AccountEntity] {
        let store = BudgetStore.shared
        guard let selection = await selectedBudget() else { return [] }
        let scoped = intent?.budget != nil
        return await store.accountsForIntent(in: selection.localID)
            .filter { !$0.closed }
            .map { account in
                AccountEntity(
                    id: scoped
                        ? AccountEntity.scopedID(budgetID: selection.scopeID, accountID: account.id)
                        : account.id,
                    name: account.name
                )
            }
    }
}
