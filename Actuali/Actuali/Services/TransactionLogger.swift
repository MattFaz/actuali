import Foundation
import os

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "TransactionLogger")

/// Headless transaction-write service used by `LogTransactionIntent`.
/// Normalizes the merchant string, matches-or-creates the payee, infers a
/// category from the most recent prior transaction at that payee, and writes
/// via `BudgetStore.createTransaction`.
@MainActor
final class TransactionLogger {
    enum LoggerError: LocalizedError, Equatable {
        case noBudgetLoaded
        case transactionAlreadyExists
        case transactionSuppressedByRule
        case transactionNeedsRecovery

        var errorDescription: String? {
            message()
        }

        func message(
            locale: Locale = .autoupdatingCurrent,
            bundle: Bundle = .main
        ) -> String {
            switch self {
            case .noBudgetLoaded:
                ReportStrings.text(
                    "Open Actuali and select a budget first.",
                    locale: locale, bundle: bundle
                )
            case .transactionAlreadyExists:
                ReportStrings.text(
                    "This transaction was already saved.",
                    locale: locale, bundle: bundle
                )
            case .transactionSuppressedByRule:
                ReportStrings.text(
                    "A transaction rule suppressed this transaction.",
                    locale: locale, bundle: bundle
                )
            case .transactionNeedsRecovery:
                ReportStrings.text(
                    "This import needs review before it can be approved.",
                    locale: locale, bundle: bundle
                )
            }
        }
    }

    /// The written row plus whether it reached the server. `synced == false`
    /// means it is queued locally for the next successful sync, which in the
    /// headless intent path may not happen until the app is opened (issue #139).
    struct Result: Sendable {
        let transaction: Transaction
        let synced: Bool
    }

    private let store: BudgetStore

    init(store: BudgetStore) {
        self.store = store
    }

    /// - Parameters:
    ///   - accountId: target Actual account id
    ///   - amountCents: signed amount in cents (negative = outflow)
    ///   - rawMerchant: merchant string from Wallet/Shortcuts (un-normalized)
    ///   - notes: optional notes from the caller
    ///   - date: transaction date
    ///   - cleared: whether the transaction is marked cleared in Actual
    ///   - categoryId: category pinned by the caller; wins over the payee
    ///     auto-pick and over rules. Ignored if it no longer exists.
    /// - Returns: the written transaction and whether it reached the server
    nonisolated static func writeTransaction(
        database: BudgetDatabase,
        accountId: String,
        amountCents: Int,
        rawMerchant: String,
        notes: String?,
        date: Date,
        cleared: Bool,
        explicitCategoryId: String?,
        financialId: String?,
        transactionId: String?,
        budgetId: String?,
        suggestCategoryFromPayeeHistory: Bool,
        write: @Sendable (Transaction, Bool) async throws -> String,
        flushPendingSync: @Sendable () async -> Void,
        hasPendingLocalWrites: @Sendable (String) async -> Bool
    ) async throws -> Result {
        let normalized = MerchantNormalizer.normalize(rawMerchant)
        let payeeName = normalized.isEmpty ? rawMerchant : normalized
        let payees = try await database.fetchPayees()
        let payee = payees.first { $0.name.lowercased() == payeeName.lowercased() }

        let pinnedCategoryId: String? = if let explicitCategoryId {
            try await database.fetchCategoryGroups().flatMap(\.categories)
                .contains(where: { $0.id == explicitCategoryId }) ? explicitCategoryId : nil
        } else {
            nil
        }
        let categoryId: String? = if let pinnedCategoryId {
            pinnedCategoryId
        } else if suggestCategoryFromPayeeHistory, let payee {
            try await database.mostRecentCategoryId(forPayeeId: payee.id)
        } else {
            nil
        }

        // Preserve the original Wallet text for rules that inspect imported_payee.
        let importedPayee = rawMerchant.isEmpty ? payeeName : rawMerchant
        var transaction = Transaction(
            id: transactionId ?? UUID().uuidString,
            accountId: accountId,
            date: Transaction.yyyymmdd(from: date),
            amount: amountCents,
            payeeId: payee?.id,
            payeeName: payee?.name ?? payeeName,
            categoryId: categoryId,
            categoryName: nil,
            notes: notes,
            cleared: cleared,
            reconciled: false,
            transferId: nil,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: nil,
            importedPayee: importedPayee
        )
        transaction.financialId = financialId

        let persistedTransactionId: String
        do {
            persistedTransactionId = try await write(transaction, pinnedCategoryId != nil)
        } catch BudgetDatabase.TransactionWriteError.incompleteFinancialIdMessages {
            throw LoggerError.transactionNeedsRecovery
        }
        guard let persistedTransaction = try await database.fetchTransaction(
            id: persistedTransactionId
        ) else {
            throw LoggerError.noBudgetLoaded
        }
        await flushPendingSync()
        let hasPendingWrites = await hasPendingLocalWrites(persistedTransactionId)
        let synced = !hasPendingWrites
        logger.info(
            "Logged transaction \(persistedTransaction.id, privacy: .public) for \(persistedTransaction.payeeName ?? payeeName, privacy: .public), synced: \(synced, privacy: .public), budget: \(budgetId ?? "active", privacy: .private)"
        )
        return Result(transaction: persistedTransaction, synced: synced)
    }

    func logTransaction(
        accountId: String,
        amountCents: Int,
        rawMerchant: String,
        notes: String?,
        date: Date,
        cleared: Bool = true,
        categoryId explicitCategoryId: String? = nil,
        financialId: String? = nil,
        transactionId: String? = nil
    ) async throws -> Result {
        guard let database = store.databaseForLogger else {
            throw LoggerError.noBudgetLoaded
        }
        let result = try await Self.writeTransaction(
            database: database,
            accountId: accountId,
            amountCents: amountCents,
            rawMerchant: rawMerchant,
            notes: notes,
            date: date,
            cleared: cleared,
            explicitCategoryId: explicitCategoryId,
            financialId: financialId,
            transactionId: transactionId,
            budgetId: store.currentBudgetId,
            suggestCategoryFromPayeeHistory: store.suggestCategoryFromPayeeHistory,
            write: { transaction, preserveCategory in
                let outcome = try await store.createTransaction(
                    transaction,
                    preserveCategory: preserveCategory,
                    resolvePayeeName: true
                )
                switch outcome {
                case .inserted(let id):
                    return id
                case .duplicate:
                    throw LoggerError.transactionAlreadyExists
                case .suppressedByRule:
                    throw LoggerError.transactionSuppressedByRule
                }
            },
            flushPendingSync: {
                await store.flushPendingSync()
            },
            hasPendingLocalWrites: { id in
                await store.hasPendingLocalWrites(
                    dataset: Transaction.datasetName, row: id
                )
            }
        )
        if let payeeId = result.transaction.payeeId {
            store.recordPayeeLocationIfAppropriate(payeeId: payeeId)
        }
        return result
    }
}

/// A second local budget's writer for headless App Intent runs. The active
/// budget continues to use TransactionLogger/BudgetStore's existing connection.
actor BudgetTransactionWriter {
    struct WriteResult: Sendable {
        let transactionId: String
        let payeeId: String?
        let payeeName: String?
        let synced: Bool
    }

    let budgetId: String
    private(set) var currencyCode: String
    private(set) var numberFormat: ActualNumberFormat

    private var database: BudgetDatabase?
    private var syncClient: SyncClient?
    private var suggestCategoryFromPayeeHistory: Bool
    private let ownsResources: Bool
    private var catchUpTask: Task<Void, Never>?
    private var isClosing = false
    private var activeWrites = 0
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeTask: Task<Void, Never>?

    init(
        database: BudgetDatabase,
        syncClient: SyncClient,
        budgetId: String,
        currencyCode: String,
        numberFormat: ActualNumberFormat,
        suggestCategoryFromPayeeHistory: Bool,
        ownsResources: Bool
    ) {
        self.database = database
        self.syncClient = syncClient
        self.budgetId = budgetId
        self.currencyCode = currencyCode
        self.numberFormat = numberFormat
        self.suggestCategoryFromPayeeHistory = suggestCategoryFromPayeeHistory
        self.ownsResources = ownsResources
    }

    static func open(
        metadata: BudgetMetadata,
        fileManager: BudgetFileManager,
        serverClient: ActualServerClient,
        nodeId: String,
        cachedCurrencyCode: String?,
        suggestCategoryFromPayeeHistory: Bool
    ) async throws -> BudgetTransactionWriter {
        guard fileManager.budgetExists(metadata.id) else {
            throw TransactionLogger.LoggerError.noBudgetLoaded
        }

        // A restored backup has no valid server group until it is re-downloaded.
        if metadata.cloudFileId != nil, metadata.groupId?.isEmpty != false {
            throw TransactionLogger.LoggerError.noBudgetLoaded
        }

        let fileId = metadata.cloudFileId ?? metadata.id
        // Match loadLocalBudget: the encrypted file's key is keyed by cloud
        // file id and may not be represented in archived metadata.json.
        let loadedKey = EncryptionKeyManager.load(fileId: fileId)

        let database = try BudgetDatabase(path: fileManager.databasePath(for: metadata.id))
        let currencyCode = try await database.fetchCurrencyCode() ?? cachedCurrencyCode ?? "USD"
        let storedNumberFormat = try await database.fetchPreference(id: "numberFormat")
        let numberFormat = storedNumberFormat
            .flatMap(ActualNumberFormat.init(rawValue:)) ?? .commaDot
        let syncClient = SyncClient(serverClient: serverClient, nodeId: nodeId)
        try await syncClient.configure(
            database: database,
            fileId: fileId,
            groupId: metadata.groupId ?? "",
            encryptionKey: loadedKey?.key,
            keyId: loadedKey?.keyId
        )
        let writer = BudgetTransactionWriter(
            database: database,
            syncClient: syncClient,
            budgetId: metadata.id,
            currencyCode: currencyCode,
            numberFormat: numberFormat,
            suggestCategoryFromPayeeHistory: suggestCategoryFromPayeeHistory,
            ownsResources: true
        )
        // The queue may already contain messages from an earlier offline
        // Wallet run. Keep its catch-up task with the writer so close() can
        // cancel and await it before releasing the database.
        await writer.resumePendingLocalWrites()
        return writer
    }

    /// A newly downloaded snapshot must catch up with the server before a
    /// shortcut reads account/category state or applies transaction rules.
    func catchUpDownloadedBudget() async -> Bool {
        guard !isClosing, let syncClient else { return false }
        return await syncClient.automaticSync()
    }

    private func resumePendingLocalWrites() async {
        guard let syncClient, await syncClient.hasPendingLocalWrites() else { return }
        catchUpTask = Task {
            guard !Task.isCancelled else { return }
            await syncClient.automaticSync()
        }
    }

    func updatePreferences(
        currencyCode: String?,
        numberFormat: ActualNumberFormat?,
        suggestCategoryFromPayeeHistory: Bool
    ) {
        if let currencyCode {
            self.currencyCode = currencyCode
        }
        if let numberFormat {
            self.numberFormat = numberFormat
        }
        self.suggestCategoryFromPayeeHistory = suggestCategoryFromPayeeHistory
    }

    func logTransaction(
        accountId: String,
        amountCents: Int,
        rawMerchant: String,
        notes: String?,
        date: Date,
        cleared: Bool = true,
        categoryId explicitCategoryId: String? = nil,
        financialId: String? = nil,
        transactionId: String? = nil
    ) async throws -> WriteResult {
        guard !isClosing, let database, let syncClient else {
            throw TransactionLogger.LoggerError.noBudgetLoaded
        }
        activeWrites += 1
        defer {
            activeWrites -= 1
            if isClosing, activeWrites == 0 {
                let waiters = closeWaiters
                closeWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        let result = try await TransactionLogger.writeTransaction(
            database: database,
            accountId: accountId,
            amountCents: amountCents,
            rawMerchant: rawMerchant,
            notes: notes,
            date: date,
            cleared: cleared,
            explicitCategoryId: explicitCategoryId,
            financialId: financialId,
            transactionId: transactionId,
            budgetId: budgetId,
            suggestCategoryFromPayeeHistory: suggestCategoryFromPayeeHistory,
            write: { transaction, preserveCategory in
                let outcome = try await syncClient.createTransaction(
                    transaction,
                    preserveCategory: preserveCategory,
                    resolvePayeeName: true
                )
                switch outcome {
                case .inserted(let id):
                    return id
                case .duplicate:
                    throw TransactionLogger.LoggerError.transactionAlreadyExists
                case .suppressedByRule:
                    throw TransactionLogger.LoggerError.transactionSuppressedByRule
                }
            },
            flushPendingSync: {
                await syncClient.flushPendingSync()
            },
            hasPendingLocalWrites: { id in
                await syncClient.hasPendingLocalWrites(
                    dataset: Transaction.datasetName, row: id
                )
            }
        )
        return WriteResult(
            transactionId: result.transaction.id,
            payeeId: result.transaction.payeeId,
            payeeName: result.transaction.payeeName,
            synced: result.synced
        )
    }

    /// Read through the writer's existing SQLite connection while resolving a shortcut.
    func accountsForIntent() async -> [Account] {
        guard !isClosing, let database else { return [] }
        let accounts = try? await database.fetchAccounts()
        return accounts ?? []
    }

    func categoriesForIntent() async -> [Category] {
        guard !isClosing, let database else { return [] }
        let groups = try? await database.fetchCategoryGroups()
        return groups?.flatMap(\.categories) ?? []
    }

    func cardMappingsForIntent() async -> [String: String] {
        guard !isClosing, let database else { return [:] }
        let mappings = try? await database.fetchCardAccountMappings()
        return mappings ?? [:]
    }

    /// Wait for in-flight writes before releasing the DB connection. Offline
    /// messages remain durable in SQLite and will sync when the budget is opened.
    func close() async {
        if let closeTask {
            await closeTask.value
            return
        }
        isClosing = true
        let syncClient = self.syncClient
        let catchUpTask = self.catchUpTask
        let ownsResources = self.ownsResources
        self.catchUpTask = nil
        let task = Task { [weak self] in
            // Flush waits for a network push. Cancel it before waiting for any
            // in-flight write to finish, so offline switches cannot hang.
            if ownsResources {
                await syncClient?.cancelPendingSync()
            }
            catchUpTask?.cancel()
            await catchUpTask?.value
            await self?.waitForInFlightWrites()
            // An in-flight write can schedule a fresh push after the first
            // cancellation. Drain it before dropping the database connection.
            if ownsResources {
                await syncClient?.cancelPendingSync()
            }
            await self?.releaseResources()
        }
        closeTask = task
        await task.value
    }

    private func releaseResources() {
        database = nil
        syncClient = nil
    }

    private func waitForInFlightWrites() async {
        guard activeWrites > 0 else { return }
        await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
        }
    }
}

/// One cached non-active writer per local budget id. Opening is shared so two
/// rapid Wallet invocations cannot create competing SyncClients for one file.
actor BudgetTransactionWriterRegistry {
    private enum Entry {
        case opening(UUID, Task<BudgetTransactionWriter, any Error>)
        case ready(BudgetTransactionWriter)
        case closing(UUID, Task<Void, Never>)
    }

    private var entries: [String: Entry] = [:]
    // Each resolved intent owns a lease. Two overlapping Wallet taps must not
    // close a shared writer while the second tap is still resolving its account.
    private var leases: [String: Int] = [:]
    private var isRejectingNewWriters = false
    private var rejectedBudgetIds: Set<String> = []

    func writer(
        for budgetId: String,
        open: @escaping @Sendable () async throws -> BudgetTransactionWriter
    ) async throws -> BudgetTransactionWriter {
        while true {
            guard !isRejectingNewWriters, !rejectedBudgetIds.contains(budgetId) else {
                throw TransactionLogger.LoggerError.noBudgetLoaded
            }
            switch entries[budgetId] {
            case .some(.ready(let writer)):
                leases[budgetId, default: 0] += 1
                return writer
            case .some(.opening(let token, let task)):
                let writer = try await task.value
                guard !isRejectingNewWriters, !rejectedBudgetIds.contains(budgetId) else {
                    throw TransactionLogger.LoggerError.noBudgetLoaded
                }
                switch entries[budgetId] {
                case .some(.opening(let currentToken, _)) where currentToken == token:
                    entries[budgetId] = .ready(writer)
                    leases[budgetId, default: 0] += 1
                    return writer
                case .some(.ready(let readyWriter)):
                    // Another waiter may have finished registering this same shared open.
                    leases[budgetId, default: 0] += 1
                    return readyWriter
                default:
                    throw TransactionLogger.LoggerError.noBudgetLoaded
                }
            case .some(.closing(let token, let task)):
                await task.value
                if case .some(.closing(let currentToken, _)) = entries[budgetId],
                   currentToken == token {
                    entries[budgetId] = nil
                }
            case .none:
                let token = UUID()
                let task = Task { try await open() }
                entries[budgetId] = .opening(token, task)
                do {
                    let writer = try await task.value
                    guard !isRejectingNewWriters, !rejectedBudgetIds.contains(budgetId) else {
                        throw TransactionLogger.LoggerError.noBudgetLoaded
                    }
                    switch entries[budgetId] {
                    case .some(.opening(let currentToken, _)) where currentToken == token:
                        entries[budgetId] = .ready(writer)
                        leases[budgetId, default: 0] += 1
                        return writer
                    case .some(.ready(let readyWriter)):
                        // A concurrent waiter may have registered the shared open first.
                        leases[budgetId, default: 0] += 1
                        return readyWriter
                    default:
                        throw TransactionLogger.LoggerError.noBudgetLoaded
                    }
                } catch {
                    if case .some(.opening(let currentToken, _)) = entries[budgetId],
                       currentToken == token {
                        entries[budgetId] = nil
                    }
                    throw error
                }
            }
        }
    }

    /// Close only after the last overlapping intent releases its claim.
    func release(budgetId: String) async {
        guard let count = leases[budgetId] else { return }
        if count > 1 {
            leases[budgetId] = count - 1
        } else {
            leases[budgetId] = nil
            await close(budgetId: budgetId)
        }
    }

    func close(budgetId: String) async {
        leases[budgetId] = nil
        switch entries[budgetId] {
        case .some(.ready(let writer)):
            let token = UUID()
            let task = Task { await writer.close() }
            entries[budgetId] = .closing(token, task)
            await task.value
            if case .some(.closing(let currentToken, _)) = entries[budgetId],
               currentToken == token {
                entries[budgetId] = nil
            }
        case .some(.opening(_, let openingTask)):
            let token = UUID()
            let task = Task {
                let writer = try? await openingTask.value
                await writer?.close()
            }
            entries[budgetId] = .closing(token, task)
            await task.value
            if case .some(.closing(let currentToken, _)) = entries[budgetId],
               currentToken == token {
                entries[budgetId] = nil
            }
        case .some(.closing(let token, let task)):
            await task.value
            if case .some(.closing(let currentToken, _)) = entries[budgetId],
               currentToken == token {
                entries[budgetId] = nil
            }
        case .none:
            return
        }
    }

    func closeAll(rejectNewWriters: Bool = false) async {
        if rejectNewWriters {
            isRejectingNewWriters = true
        }
        for budgetId in Array(entries.keys) {
            await close(budgetId: budgetId)
        }
    }

    func closeAndReject(budgetId: String) async {
        rejectedBudgetIds.insert(budgetId)
        await close(budgetId: budgetId)
    }

    func allowWriters(for budgetId: String) {
        rejectedBudgetIds.remove(budgetId)
    }

    func allowNewWriters() {
        isRejectingNewWriters = false
    }
}
