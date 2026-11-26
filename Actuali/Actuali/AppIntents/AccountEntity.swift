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

    /// The local file and entity-ID scope a dependent account/category query reads.
    @MainActor
    static func selection(for budget: BudgetEntity?) async -> (localID: String, scopeID: String)? {
        let store = BudgetStore.shared
        if let budget {
            guard let localID = try? await store.localBudgetIDForIntent(budget.id) else {
                return nil
            }
            return (localID, budget.id)
        }
        guard !(store.isConnected && store.currentBudgetId == DemoDataSeeder.budgetId),
              let currentBudgetID = store.currentBudgetId else {
            return nil
        }
        return (currentBudgetID, currentBudgetID)
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
            where metadata.canWriteToLocally {
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
        return (entities, store.isConnected)
    }

    @MainActor
    static func needsRemoteFetch(
        identifiers: [BudgetEntity.ID],
        entities: [BudgetEntity],
        isConnected: Bool
    ) -> Bool {
        isConnected && identifiers.contains { identifier in
            !entities.contains(where: { $0.id == identifier })
        }
    }

    @MainActor
    func entities(for identifiers: [BudgetEntity.ID]) async throws -> [BudgetEntity] {
        var result = await available(fetchRemote: false)
        if Self.needsRemoteFetch(
            identifiers: identifiers, entities: result.entities, isConnected: result.isConnected
        ) {
            result = await available()
        }
        let requested = Set(identifiers)
        return result.entities.filter { requested.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [BudgetEntity] {
        await available().entities
    }
}

/// A row identifier is scoped to the selected budget entity's ID. Unscoped IDs
/// are accepted only when no budget parameter was supplied.
enum ScopedEntityID {
    private static let separator = "|"

    static func make(budgetID: String, rowID: String) -> String {
        "\(budgetID)\(separator)\(rowID)"
    }

    static func rowID(_ entityID: String, budgetID: String, allowLegacyID: Bool) -> String? {
        if let range = entityID.range(of: separator) {
            guard entityID[..<range.lowerBound] == budgetID else { return nil }
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
        await BudgetEntity.selection(for: intent?.budget)
    }

    @MainActor
    func entities(for identifiers: [AccountEntity.ID]) async throws -> [AccountEntity] {
        let store = BudgetStore.shared
        guard let selection = await selectedBudget() else { return [] }
        let scoped = intent?.budget != nil
        let accounts = await store.accountsForIntent(in: selection.localID)
        let requestedIDs = Set(identifiers.compactMap { identifier in
            ScopedEntityID.rowID(identifier, budgetID: selection.scopeID, allowLegacyID: !scoped)
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
