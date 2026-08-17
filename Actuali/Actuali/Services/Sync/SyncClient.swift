// Actuali/Actuali/Services/Sync/SyncClient.swift

import Foundation
import Combine
import CryptoKit
import os

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "SyncClient")

enum SyncError: LocalizedError, Equatable {
    case notConfigured
    case offline
    case outOfSync
    case encodingFailed
    case serverError(String)
    case budgetTableMissing
    case notesTableMissing

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Sync isn't configured. Open a budget first."
        case .offline:
            return "You're offline. Sync will resume automatically."
        case .outOfSync:
            return "Local data has drifted from the server and couldn't reconcile after several attempts. Tap \"Reset Sync State\" below to recover."
        case .encodingFailed:
            return "Failed to encode the sync request."
        case .serverError(let message):
            return "Server error: \(message)"
        case .budgetTableMissing:
            return "This budget file has no budget table to write to."
        case .notesTableMissing:
            return "This budget file has no notes table to write to."
        }
    }
}

enum SyncState: Equatable {
    case idle
    case syncing
    case offline
    case error(String)
}

/// Main sync orchestrator
actor SyncClient {
    // MARK: - Dependencies

    private let serverClient: ActualServerClient
    private weak var database: BudgetDatabase?
    private let clock: HybridLogicalClock
    private let messageGenerator: MessageGenerator

    // MARK: - State

    private var merkle: MerkleTree
    private var encoder: SyncEncoder
    private var syncTask: Task<Void, Never>?
    private var retryDelay: TimeInterval = 5
    private let maxRetryDelay: TimeInterval = 300  // 5 min cap

    /// The detached push kicked off by the most recent local write (see
    /// `scheduleAutomaticSync`). Nil when no push is in flight.
    private var pushTask: Task<Void, Never>?
    /// Set when a write lands while `pushTask` is running, so its messages get
    /// a trailing push instead of waiting for the next sync event.
    private var pushNeededAfterCurrent = false

    private var fileId: String?
    private var groupId: String?
    private var encryptKeyId: String?
    private var lastSyncedTimestamp: String?
    private var lastSuccessfulSyncTime: Date?
    /// The server's message high-water mark at budget-load time (max timestamp in
    /// `messages_crdt` when `configure` ran, before any local writes this session).
    /// On a fresh download `lastSyncedTimestamp` is nil, so this is the floor for
    /// deciding which local messages are genuine post-download writes that must be
    /// pushed — without it, the first local write is stranded (actios-4k4).
    private var downloadBaselineTimestamp: String?
    /// Whether the merkle has been re-derived from `messages_crdt` this session.
    /// See the top of `fullSync` for why that must happen before the first
    /// comparison against the server's tree.
    private var hasDerivedMerkleFromLog = false

    // MARK: - Published State (for UI)

    /// This device's HLC node id — the suffix stamped on every message this
    /// client authors. NewTransactionDetector uses it to skip local writes.
    nonisolated var nodeId: String { clock.node }

    nonisolated let stateSubject = CurrentValueSubject<SyncState, Never>(.idle)
    nonisolated var statePublisher: AnyPublisher<SyncState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    init(serverClient: ActualServerClient, nodeId: String? = nil) {
        self.serverClient = serverClient
        self.clock = HybridLogicalClock(node: nodeId)
        self.messageGenerator = MessageGenerator(clock: clock)
        self.merkle = MerkleTree()
        self.encoder = SyncEncoder()
    }

    // MARK: - Configuration

    func configure(
        database: BudgetDatabase,
        fileId: String,
        groupId: String,
        encryptionKey: SymmetricKey? = nil,
        keyId: String? = nil
    ) async throws {
        self.database = database
        self.fileId = fileId
        self.groupId = groupId
        self.encryptKeyId = keyId
        self.encoder = SyncEncoder(encryptionKey: encryptionKey)

        // Load saved clock state
        if let clockRecord = try database.loadClock() {
            // Restore merkle tree
            merkle = MerkleTree(root: clockRecord.merkle)
            // Only set lastSyncedTimestamp if it's valid (non-empty and not epoch)
            if !clockRecord.timestamp.isEmpty && !clockRecord.timestamp.hasPrefix("1970-") {
                lastSyncedTimestamp = clockRecord.timestamp
            } else {
                // Recover from invalid/legacy state by taking the high-water mark
                // of messages_crdt. The downloaded budget already contains all of
                // the server's messages, so any new local writes will have
                // timestamps strictly greater than this and are the only thing
                // we should be pushing on the next sync.
                let recovered = (try? database.getMaxMessageTimestamp()).flatMap { $0 }
                if let recovered, !recovered.isEmpty, !recovered.hasPrefix("1970-") {
                    lastSyncedTimestamp = recovered
                    logger.notice("Recovered lastSyncedTimestamp from messages_crdt: \(recovered, privacy: .public)")
                } else {
                    // Nothing trustworthy to recover from (empty budget).
                    // Leave nil — fullSync's no-lastSynced path syncs from the
                    // snapshot's floor rather than fabricating a timestamp.
                    lastSyncedTimestamp = nil
                    logger.notice("No recoverable lastSyncedTimestamp - deferring to first sync")
                }
            }
            logger.info("Loaded clock - merkle hash: \(self.merkle.root.hash, privacy: .public), lastSynced: \(self.lastSyncedTimestamp ?? "nil", privacy: .public)")
        }

        // Restore the HLC so it is never behind the persisted sync state or the
        // local message high-water mark (mirrors upstream setClock on budget
        // load). This lets lastSyncedTimestamp be derived from the HLC without
        // regressing to the epoch on a fresh download.
        let maxMessageTimestamp: String?
        do {
            maxMessageTimestamp = try database.getMaxMessageTimestamp()
        } catch {
            logger.warning("Failed to read max message timestamp for HLC restore: \(error, privacy: .public)")
            maxMessageTimestamp = nil
        }
        // Capture the server's state at load as the baseline for the fresh-download
        // sync path (no local writes have happened yet at configure time).
        downloadBaselineTimestamp = maxMessageTimestamp
        for candidate in [lastSyncedTimestamp, maxMessageTimestamp] {
            if let candidate, let parsed = HLCTimestamp.parse(candidate) {
                await clock.advance(to: parsed)
            }
        }
    }

    // MARK: - Public API

    /// Create a transaction (optimistic local-first).
    /// `applyRules: false` skips the rules pass — used for split children,
    /// whose every field the caller spelled out explicitly (like `createSplit`).
    func createTransaction(_ transaction: Transaction, applyRules: Bool = true) async throws {
        guard let database else { throw SyncError.notConfigured }

        logger.debug("createTransaction() - id: \(transaction.id, privacy: .private)")

        // 0. Apply user-defined rules (Actual Budget rules table) before insert.
        //    Skip for transfers — upstream runs rules on the transfer leg, but our
        //    transfer flow already builds both legs explicitly and we don't want
        //    rules rewriting the linked payee/account.
        let finalTransaction: Transaction
        if applyRules, transaction.transferId == nil {
            let rules = (try? database.fetchRules()) ?? []
            let (updated, changed) = RulesEngine.apply(transaction, rules: rules)
            if !changed.isEmpty {
                logger.info("Rules updated \(changed.count, privacy: .public) field(s) on new transaction")
            }
            finalTransaction = updated
        } else {
            finalTransaction = transaction
        }

        // 1. Insert locally (optimistic)
        try database.insertTransaction(finalTransaction)
        logger.debug("Transaction inserted locally")

        // 2. Generate CRDT messages
        let messages = try await messageGenerator.messagesForInsert(finalTransaction)
        logger.debug("Generated \(messages.count, privacy: .public) CRDT messages")

        // 3. Store messages and update merkle
        for msg in try database.insertMessages(messages) {
            merkle = merkle.inserting(msg.timestamp)
        }
        merkle = merkle.pruned()
        try saveClock()
        logger.debug("Messages stored, merkle updated (hash: \(self.merkle.root.hash, privacy: .public))")

        // 4. Push to the server in the background (never blocks the caller)
        scheduleAutomaticSync()
    }

    /// Create both legs of a transfer atomically (optimistic local-first).
    /// The two rows and all of their CRDT messages commit in a single SQLite
    /// transaction, so a failure on either leg leaves no orphaned
    /// half-transfer. Rules are skipped, same as transfer legs in
    /// `createTransaction` — the caller builds both legs explicitly.
    func createTransfer(source: Transaction, target: Transaction) async throws {
        guard let database else { throw SyncError.notConfigured }

        logger.debug("createTransfer() - source: \(source.id, privacy: .private), target: \(target.id, privacy: .private)")

        // 1. Generate CRDT messages for both legs up front
        var messages = try await messageGenerator.messagesForInsert(source)
        messages += try await messageGenerator.messagesForInsert(target)
        logger.debug("Generated \(messages.count, privacy: .public) CRDT messages for transfer")

        // 2. Persist rows + messages in one DB transaction, then update merkle
        for msg in try database.insertTransfer(source: source, target: target, messages: messages) {
            merkle = merkle.inserting(msg.timestamp)
        }
        merkle = merkle.pruned()
        try saveClock()
        logger.debug("Transfer stored, merkle updated (hash: \(self.merkle.root.hash, privacy: .public))")

        // 3. Push both legs to the server in the background
        scheduleAutomaticSync()
    }

    /// Create a split parent and its children atomically (optimistic
    /// local-first). Like transfers, all rows and their CRDT messages commit
    /// in one SQLite transaction and rules are skipped — the caller builds
    /// every row explicitly.
    func createSplit(parent: Transaction, children: [Transaction]) async throws {
        guard let database else { throw SyncError.notConfigured }

        logger.debug("createSplit() - parent: \(parent.id, privacy: .private), children: \(children.count, privacy: .public)")

        // 1. Generate CRDT messages for every row up front
        var messages = try await messageGenerator.messagesForInsert(parent)
        for child in children {
            messages += try await messageGenerator.messagesForInsert(child)
        }
        logger.debug("Generated \(messages.count, privacy: .public) CRDT messages for split")

        // 2. Persist rows + messages in one DB transaction, then update merkle
        for msg in try database.insertSplit(parent: parent, children: children, messages: messages) {
            merkle = merkle.inserting(msg.timestamp)
        }
        merkle = merkle.pruned()
        try saveClock()
        logger.debug("Split stored, merkle updated (hash: \(self.merkle.root.hash, privacy: .public))")

        // 3. Push all rows to the server in the background
        scheduleAutomaticSync()
    }

    /// Update an existing transaction (optimistic local-first)
    /// - Parameters:
    ///   - transaction: The full updated transaction (used for both local UPDATE and CRDT field values)
    ///   - changedFields: The CRDT column names that changed (e.g. "amount", "date", "category")
    func updateTransaction(_ transaction: Transaction, changedFields: Set<String>) async throws {
        guard let database else { throw SyncError.notConfigured }

        logger.debug("updateTransaction() - id: \(transaction.id, privacy: .private), fields: \(changedFields.count, privacy: .public)")

        // 1. Update locally (optimistic)
        try database.updateTransaction(transaction)
        logger.debug("Transaction updated locally")

        guard !changedFields.isEmpty else {
            logger.debug("No changed fields - skipping CRDT messages")
            return
        }

        // 2. Generate CRDT messages for the changed fields only
        let messages = try await messageGenerator.messagesForUpdate(transaction, changedFields: changedFields)
        logger.debug("Generated \(messages.count, privacy: .public) CRDT messages")

        // 3. Store messages and update merkle
        for msg in try database.insertMessages(messages) {
            merkle = merkle.inserting(msg.timestamp)
        }
        merkle = merkle.pruned()
        try saveClock()
        logger.debug("Messages stored, merkle updated (hash: \(self.merkle.root.hash, privacy: .public))")

        // 4. Push to the server in the background
        scheduleAutomaticSync()
    }

    /// Update many transactions that share one set of changed fields, in a
    /// single pass (optimistic local-first). One merkle/clock save and one
    /// sync for the whole batch — reconciliation locks every cleared row in
    /// an account, and per-row round trips made that visibly slow. Mirrors
    /// upstream's transactions-batch-update.
    func updateTransactions(_ transactions: [Transaction], changedFields: Set<String>) async throws {
        guard let database else { throw SyncError.notConfigured }
        guard !transactions.isEmpty else { return }

        logger.debug("updateTransactions() - \(transactions.count, privacy: .public) rows, fields: \(changedFields.count, privacy: .public)")

        // 1. Update locally (optimistic) and generate CRDT messages
        var messages: [CRDTMessage] = []
        for transaction in transactions {
            try database.updateTransaction(transaction)
            guard !changedFields.isEmpty else { continue }
            messages.append(contentsOf: try await messageGenerator.messagesForUpdate(
                transaction, changedFields: changedFields
            ))
        }

        // 2. Store messages and update merkle once for the batch
        for msg in try database.insertMessages(messages) {
            merkle = merkle.inserting(msg.timestamp)
        }
        merkle = merkle.pruned()
        try saveClock()
        logger.debug("Batch stored, merkle updated (hash: \(self.merkle.root.hash, privacy: .public))")

        // 3. Push to the server in the background
        scheduleAutomaticSync()
    }

    /// Create a payee (optimistic local-first)
    func createPayee(_ payee: Payee) async throws {
        guard let database else { throw SyncError.notConfigured }

        logger.debug("createPayee() - id: \(payee.id, privacy: .private), name: \(payee.name, privacy: .private)")

        // 1. Insert locally (optimistic) - includes payee_mapping
        try database.insertPayee(payee)
        logger.debug("Payee inserted locally")

        // 2. Generate CRDT messages for payee
        var messages = try await messageGenerator.messagesForInsert(payee)
        logger.debug("Generated \(messages.count, privacy: .public) CRDT messages for payee")

        // 3. Generate CRDT messages for payee_mapping
        let mapping = PayeeMapping(id: payee.id, targetId: payee.id)
        let mappingMessages = try await messageGenerator.messagesForInsert(mapping)
        messages.append(contentsOf: mappingMessages)
        logger.debug("Generated \(mappingMessages.count, privacy: .public) CRDT messages for payee_mapping")

        // 4. Store messages and update merkle
        for msg in try database.insertMessages(messages) {
            merkle = merkle.inserting(msg.timestamp)
        }
        merkle = merkle.pruned()
        try saveClock()

        // Note: Don't schedule sync here - let the transaction sync handle it
    }

    /// Create a new account, its transfer payee (the empty-named payee every
    /// transfer to or from the account resolves through — created here and
    /// nowhere else, matching the PWA), and, if given, its opening-balance
    /// transaction — atomically, so a failure on any row leaves nothing
    /// orphaned. Rules are skipped, same as `createTransfer`/`createSplit`:
    /// the caller (account creation) builds the transaction explicitly and
    /// it's never user-editable rule input.
    func createAccount(
        _ account: Account,
        transferPayee: Payee,
        startingBalanceTransaction: Transaction?
    ) async throws {
        guard let database else { throw SyncError.notConfigured }

        logger.debug("createAccount() - id: \(account.id, privacy: .private)")

        // 1. Insert locally (optimistic)
        try database.insertAccount(
            account,
            transferPayee: transferPayee,
            startingBalanceTransaction: startingBalanceTransaction
        )
        logger.debug("Account inserted locally")

        // 2. Generate CRDT messages for the account row
        var messages = try await messageGenerator.messagesForInsert(account)

        // 3. Generate CRDT messages for the transfer payee and its mapping,
        //    same pair `createPayee` emits.
        messages += try await messageGenerator.messagesForInsert(transferPayee)
        messages += try await messageGenerator.messagesForInsert(
            PayeeMapping(id: transferPayee.id, targetId: transferPayee.id)
        )

        // 4. Generate CRDT messages for the opening-balance transaction, if any
        if let startingBalanceTransaction {
            messages += try await messageGenerator.messagesForInsert(startingBalanceTransaction)
        }
        logger.debug("Generated \(messages.count, privacy: .public) CRDT messages for new account")

        // 5. Store messages and update merkle
        for msg in try database.insertMessages(messages) {
            merkle = merkle.inserting(msg.timestamp)
        }
        merkle = merkle.pruned()
        try saveClock()

        // 6. Sync to push the new account to the server (rate-limited)
        await automaticSync()
    }

    /// Record a location for a payee (optimistic local-first). Callers are
    /// responsible for the server-version guard and 500 m dedupe — this
    /// method just writes.
    func createPayeeLocation(_ location: PayeeLocation) async throws {
        guard let database else { throw SyncError.notConfigured }

        logger.debug("createPayeeLocation() - payee: \(location.payeeId, privacy: .private)")

        // 1. Insert locally (optimistic)
        try database.insertPayeeLocation(location)
        logger.debug("Payee location inserted locally")

        // 2. Generate CRDT messages
        let messages = try await messageGenerator.messagesForInsert(location)
        logger.debug("Generated \(messages.count, privacy: .public) CRDT messages for payee location")

        // 3. Store messages and update merkle
        for msg in try database.insertMessages(messages) {
            merkle = merkle.inserting(msg.timestamp)
        }
        merkle = merkle.pruned()
        try saveClock()

        // 4. Push to the server in the background
        scheduleAutomaticSync()
    }

    /// Tombstone a recorded payee location (optimistic local-first).
    func deletePayeeLocation(_ location: PayeeLocation) async throws {
        guard let database else { throw SyncError.notConfigured }

        logger.debug("deletePayeeLocation() - id: \(location.id, privacy: .private)")

        // 1. Tombstone locally (optimistic)
        try database.tombstonePayeeLocation(id: location.id)

        // 2. Generate the tombstone CRDT message
        let message = try await messageGenerator.messageForDelete(location)

        // 3. Store the message and update merkle
        for msg in try database.insertMessages([message]) {
            merkle = merkle.inserting(msg.timestamp)
        }
        merkle = merkle.pruned()
        try saveClock()

        // 4. Push to the server in the background
        scheduleAutomaticSync()
    }

    /// Tombstone several recorded payee locations at once ("Clear All
    /// Locations"). One tombstone message per location, but a single sync —
    /// looping `deletePayeeLocation` would kick off a sync per row.
    func deletePayeeLocations(_ locations: [PayeeLocation]) async throws {
        guard let database else { throw SyncError.notConfigured }
        guard !locations.isEmpty else { return }

        logger.debug("deletePayeeLocations() - count: \(locations.count, privacy: .public)")

        // 1. Tombstone locally (optimistic)
        for location in locations {
            try database.tombstonePayeeLocation(id: location.id)
        }

        // 2. Generate one tombstone CRDT message per location
        var messages: [CRDTMessage] = []
        for location in locations {
            messages.append(try await messageGenerator.messageForDelete(location))
        }

        // 3. Store the messages and update merkle
        for msg in try database.insertMessages(messages) {
            merkle = merkle.inserting(msg.timestamp)
        }
        merkle = merkle.pruned()
        try saveClock()

        // 4. Push to the server in the background
        scheduleAutomaticSync()
    }

    /// Persist the currency code to the budget's `preferences` table (Actual's
    /// `defaultCurrencyCode`), so the choice survives a relaunch and syncs to
    /// other clients. Without this, the picker only ever wrote to
    /// UserDefaults — the value the app treats as authoritative on every DB
    /// load was never updated, so it silently reverted to whatever the
    /// server/PWA last set (GH #59).
    func updateCurrencyCode(_ code: String) async throws {
        guard let database else { throw SyncError.notConfigured }

        logger.debug("updateCurrencyCode() - code: \(code, privacy: .public)")

        let fields: [(column: String, value: Any?)] = [("value", code)]
        let messages = try await messageGenerator.messages(dataset: "preferences", row: "defaultCurrencyCode", fields: fields)
        logger.debug("Generated \(messages.count, privacy: .public) CRDT messages")

        // 2. Apply locally (optimistic) through the same LWW upsert incoming
        //    messages use, so a local edit and the identical edit arriving
        //    from another device converge byte-for-byte.
        try database.applyMessages(messages)

        // 3. Store messages and update merkle
        for msg in try database.insertMessages(messages) {
            merkle = merkle.inserting(msg.timestamp)
        }
        merkle = merkle.pruned()
        try saveClock()
        logger.debug("Messages stored, merkle updated (hash: \(self.merkle.root.hash, privacy: .public))")

        // 4. Push to the server in the background
        scheduleAutomaticSync()
    }

    /// Set the budgeted amount for a category in a month (optimistic
    /// local-first). Mirrors upstream setBudget: update the existing
    /// (month, category) row's amount, or create the row with the
    /// {YYYYMM}-{categoryId} id and its month/category columns.
    func setBudgetAmount(month: String, categoryId: String, amount: Int) async throws {
        guard let database else { throw SyncError.notConfigured }

        logger.debug("setBudgetAmount() - month: \(month, privacy: .public), category: \(categoryId, privacy: .private), amount: \(amount, privacy: .private)")

        guard let cell = try database.budgetCell(month: month, categoryId: categoryId) else {
            throw SyncError.budgetTableMissing
        }

        // 1. Generate CRDT messages (before any DB write, so an HLC failure
        //    leaves nothing stranded)
        var fields: [(column: String, value: Any?)] = []
        if !cell.exists {
            fields.append(("month", cell.monthInt))
            fields.append(("category", categoryId))
        }
        fields.append(("amount", amount))
        let messages = try await messageGenerator.messages(dataset: cell.table, row: cell.rowId, fields: fields)
        logger.debug("Generated \(messages.count, privacy: .public) CRDT messages")

        // 2. Apply locally (optimistic) through the same LWW upsert incoming
        //    messages use, so a local edit and the identical edit arriving
        //    from another device converge byte-for-byte.
        try database.applyMessages(messages)

        // 3. Store messages and update merkle
        for msg in try database.insertMessages(messages) {
            merkle = merkle.inserting(msg.timestamp)
        }
        merkle = merkle.pruned()
        try saveClock()
        logger.debug("Messages stored, merkle updated (hash: \(self.merkle.root.hash, privacy: .public))")

        // 4. Push to the server in the background
        scheduleAutomaticSync()
    }

    /// Move budgeted funds between two categories in a month, or between a
    /// category and "To Budget" (nil side), optimistic local-first. Mirrors
    /// upstream transferCategory / coverOverspending / transferAvailable
    /// (loot-core budget/actions.ts): the source cell's amount shrinks, the
    /// destination cell's grows, and the To Budget figure — being derived —
    /// needs no write at all. Both cells go out in one message batch so a
    /// failure can't strand half the transfer.
    func transferBudget(month: String, fromCategoryId: String?, toCategoryId: String?, amount: Int) async throws {
        guard let database else { throw SyncError.notConfigured }

        logger.debug("transferBudget() - month: \(month, privacy: .public), from: \(fromCategoryId ?? "to-budget", privacy: .private), to: \(toCategoryId ?? "to-budget", privacy: .private), amount: \(amount, privacy: .private)")

        // 1. Generate CRDT messages for both cells (before any DB write, so
        //    an HLC failure leaves nothing stranded)
        var messages: [CRDTMessage] = []
        for (categoryId, delta) in [(fromCategoryId, -amount), (toCategoryId, amount)] {
            guard let categoryId else { continue } // To Budget side is derived
            guard let cell = try database.budgetCell(month: month, categoryId: categoryId) else {
                throw SyncError.budgetTableMissing
            }
            var fields: [(column: String, value: Any?)] = []
            if !cell.exists {
                fields.append(("month", cell.monthInt))
                fields.append(("category", categoryId))
            }
            fields.append(("amount", cell.amount + delta))
            messages += try await messageGenerator.messages(dataset: cell.table, row: cell.rowId, fields: fields)
        }
        logger.debug("Generated \(messages.count, privacy: .public) CRDT messages")

        // 2. Apply locally (optimistic) through the same LWW upsert incoming
        //    messages use, so a local edit and the identical edit arriving
        //    from another device converge byte-for-byte.
        try database.applyMessages(messages)

        // 3. Store messages and update merkle
        for msg in try database.insertMessages(messages) {
            merkle = merkle.inserting(msg.timestamp)
        }
        merkle = merkle.pruned()
        try saveClock()
        logger.debug("Messages stored, merkle updated (hash: \(self.merkle.root.hash, privacy: .public))")

        // 4. Push to the server in the background
        scheduleAutomaticSync()
    }

    /// Save the note attached to a row — a category, for now (GH #131) —
    /// optimistic local-first. Mirrors upstream notes-save (loot-core
    /// server/notes/app.ts): a single `note` cell on the `notes` table, keyed
    /// by the annotated row's own id. No row is created up front: the CRDT
    /// apply upserts, so a category that has never been annotated gets its row
    /// from this write.
    ///
    /// Clearing a note saves an empty string rather than tombstoning the row,
    /// again matching upstream — a tombstone would leave other clients showing
    /// the stale note, since they read the note column, not the tombstone.
    ///
    /// Requires the `notes` table: without it `applyMessages` would skip the
    /// local apply as unknown schema and the write would look like it worked
    /// while changing nothing on screen.
    func setNote(id: String, note: String) async throws {
        guard let database else { throw SyncError.notConfigured }
        guard try database.notesTableExists() else { throw SyncError.notesTableMissing }

        logger.debug("setNote() - row: \(id, privacy: .private), length: \(note.count, privacy: .public)")

        // 1. Generate CRDT messages (before any DB write, so an HLC failure
        //    leaves nothing stranded)
        let messages = try await messageGenerator.messages(
            dataset: "notes", row: id, fields: [("note", note)])

        // 2. Apply locally (optimistic) through the same LWW upsert incoming
        //    messages use, so a local edit and the identical edit arriving from
        //    another device converge byte-for-byte.
        try database.applyMessages(messages)

        // 3. Store messages and update merkle
        for msg in try database.insertMessages(messages) {
            merkle = merkle.inserting(msg.timestamp)
        }
        merkle = merkle.pruned()
        try saveClock()
        logger.debug("Messages stored, merkle updated (hash: \(self.merkle.root.hash, privacy: .public))")

        // 4. Push in the background — the Save button awaits this write, and
        //    an unreachable server must not hold the sheet open (issue #125).
        scheduleAutomaticSync()
    }

    /// Advance a schedule's next date after posting (optimistic local-first).
    /// Mirrors loot-core setNextDate (non-reset branch): `local_next_date`
    /// moves, and `local_next_date_ts` copies the CURRENT `base_next_date_ts`
    /// so the local override stays valid (per the v_schedules CASE rule) until
    /// another client resets the base. `base_next_date`/`base_next_date_ts`
    /// are never touched.
    func advanceScheduleNextDate(nextDateRowId: String, newNextDate: Int, baseNextDateTs: Int64?) async throws {
        guard let database else { throw SyncError.notConfigured }

        logger.debug("advanceScheduleNextDate() - row: \(nextDateRowId, privacy: .private), newDate: \(newNextDate, privacy: .public)")

        // 1. Generate CRDT messages (before any DB write, so an HLC failure
        //    leaves nothing stranded)
        // .map flattens Int64? into Any? so a NULL base ts serializes through
        // CRDTValue's nil case ("0:"), the null loot-core's setNextDate writes.
        let fields: [(column: String, value: Any?)] = [
            ("local_next_date", newNextDate),
            ("local_next_date_ts", baseNextDateTs.map { $0 as Any }),
        ]
        let messages = try await messageGenerator.messages(dataset: "schedules_next_date", row: nextDateRowId, fields: fields)
        logger.debug("Generated \(messages.count, privacy: .public) CRDT messages")

        // 2. Apply locally (optimistic) through the same LWW upsert incoming
        //    messages use, so a local advance and the identical advance
        //    arriving from another device converge byte-for-byte.
        try database.applyMessages(messages)

        // 3. Store messages and update merkle
        for msg in try database.insertMessages(messages) {
            merkle = merkle.inserting(msg.timestamp)
        }
        merkle = merkle.pruned()
        try saveClock()
        logger.debug("Messages stored, merkle updated (hash: \(self.merkle.root.hash, privacy: .public))")

        // 4. Push to the server in the background
        scheduleAutomaticSync()
    }
    
    /// Skip the current occurrence. Port of loot-core `skipNextDate`: search
    /// for the next occurrence starting the day AFTER the current one, and
    /// move only the local override.
    func skipScheduleNextDate(_ schedule: ScheduleSummary) async throws {
        guard let currentNextDate = schedule.nextDate,
              case .recurring(let config)? = schedule.dateCondition
        else { throw ScheduleWriteError.notRecurring }

        guard let next = ScheduleRecurrence.nextOccurrence(
            config: config,
            onOrAfter: ScheduleRecurrence.skipSearchStart(from: currentNextDate, config: config)),
            next != currentNextDate
        else { return }

        try await setScheduleNextDate(schedule, to: next, reset: false)
    }

    /// Post a transaction for a schedule now. Port of loot-core
    /// `postTransactionForSchedule`.
    ///
    /// Deliberately does NOT advance the next date — upstream leaves that to
    /// the advance service, which will see the posted transaction through the
    /// same dedup guard the auto-poster uses and move the schedule on.
    func postScheduleTransaction(_ schedule: ScheduleSummary, today: Bool) async throws {
        guard let accountId = schedule.accountId else { throw ScheduleWriteError.noAccount }
        let date = today ? DayDate.today() : (schedule.nextDate ?? DayDate.today())

        var transaction = Transaction(
            id: UUID().uuidString.lowercased(),
            accountId: accountId,
            date: date.yyyymmdd,
            amount: schedule.postAmount,
            payeeId: schedule.payeeId,
            payeeName: nil,
            categoryId: schedule.categoryId,
            categoryName: nil,
            notes: nil,
            cleared: false,
            reconciled: false,
            transferId: nil,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: nil,
            importedPayee: nil)
        transaction.schedule = schedule.id

        try await createTransaction(transaction, applyRules: true)
    }

    /// Mark a schedule finished, or restart it. Restarting also resets the
    /// next date, matching the web's "restart" menu item
    /// (`resetNextDate: true`) — a schedule resumed without that would still
    /// be sitting on a date in the past.
    func setScheduleCompleted(
        _ schedule: ScheduleSummary,
        completed: Bool,
        today: DayDate = .today()
    ) async throws {
        try await updateScheduleColumns(
            scheduleId: schedule.id,
            fields: [("completed", completed ? 1 : 0)])

        guard !completed,
              let date = schedule.dateCondition,
              let next = ScheduleConditions.nextDate(for: date, from: today)
        else { return }
        try await setScheduleNextDate(schedule, to: next, reset: true)
    }

    /// Apply one schedule write plan: local rows, CRDT messages, JSON-path
    /// cache, push.
    ///
    /// All of a plan's rows go out in a single message batch, so a failure
    /// can't leave a schedule with a rule but no next date — the state that
    /// makes a schedule invisible to the web.
    private func commit(_ plan: ScheduleWritePlan) async throws {
        guard let database else { throw SyncError.notConfigured }

        // 1. Generate every message first, before any DB write, so an HLC
        //    failure leaves nothing stranded.
        var messages: [CRDTMessage] = []
        for write in plan.writes {
            messages += try await messageGenerator.messages(
                dataset: write.dataset, row: write.row, fields: write.fields)
        }

        // 2. Apply locally (optimistic) through the same LWW upsert incoming
        //    messages use, so a local edit and the identical edit arriving
        //    from another device converge byte-for-byte.
        try database.applyMessages(messages)

        // 3. Store messages and update merkle
        for msg in try database.insertMessages(messages) {
            merkle = merkle.inserting(msg.timestamp)
        }
        merkle = merkle.pruned()
        try saveClock()

        // 4. Local-only derived cache; never synced (see BudgetDatabase).
        if let conditions = plan.conditions {
            try database.writeScheduleJSONPaths(
                scheduleId: plan.scheduleId, conditions: conditions)
        }

        // 5. Push in the background — the save button awaits this write, and
        //    an unreachable server must not hold the editor open (issue #125).
        scheduleAutomaticSync()
    }

    /// Create a schedule and its linked rule (optimistic local-first).
    /// Mirrors loot-core `createSchedule`.
    @discardableResult
    func createSchedule(fields: ScheduleFormFields, today: DayDate = .today()) async throws -> String {
        guard let database else { throw SyncError.notConfigured }

        if let name = fields.normalizedName,
           try database.scheduleNameExists(name, excluding: nil) {
            throw ScheduleWriteError.duplicateName(name)
        }

        let plan = try ScheduleWriteBuilder.createPlan(
            fields: fields,
            scheduleId: UUID().uuidString.lowercased(),
            ruleId: UUID().uuidString.lowercased(),
            nextDateRowId: UUID().uuidString.lowercased(),
            now: Self.nowMilliseconds(),
            today: today)

        logger.debug("createSchedule() - id: \(plan.scheduleId, privacy: .private)")
        try await commit(plan)
        return plan.scheduleId
    }

    /// Update a schedule's fields, merging into its existing rule.
    /// Mirrors loot-core `updateSchedule`.
    func updateSchedule(
        _ schedule: ScheduleSummary,
        fields: ScheduleFormFields,
        resetNextDate: Bool = false,
        today: DayDate = .today()
    ) async throws {
        guard let database else { throw SyncError.notConfigured }

        if let name = fields.normalizedName,
           try database.scheduleNameExists(name, excluding: schedule.id) {
            throw ScheduleWriteError.duplicateName(name)
        }

        let plan = try ScheduleWriteBuilder.updatePlan(
            schedule: schedule,
            fields: fields,
            now: Self.nowMilliseconds(),
            today: today,
            resetRequested: resetNextDate)

        logger.debug("updateSchedule() - id: \(schedule.id, privacy: .private)")
        try await commit(plan)
    }

    /// Tombstone a schedule and its rule. Mirrors loot-core `deleteSchedule`.
    func deleteSchedule(_ schedule: ScheduleSummary) async throws {
        logger.debug("deleteSchedule() - id: \(schedule.id, privacy: .private)")
        try await commit(ScheduleWriteBuilder.deletePlan(schedule: schedule))
    }

    /// Move a schedule's next date. `reset` bumps the canonical base; the
    /// non-reset branch moves only the local override.
    func setScheduleNextDate(
        _ schedule: ScheduleSummary,
        to newNextDate: DayDate,
        reset: Bool
    ) async throws {
        guard let plan = ScheduleWriteBuilder.nextDatePlan(
            schedule: schedule,
            newNextDate: newNextDate,
            reset: reset,
            now: Self.nowMilliseconds())
        else { return }
        try await commit(plan)
    }

    /// Write plain columns on the schedule row (complete, restart).
    func updateScheduleColumns(
        scheduleId: String,
        fields: [(column: String, value: Any?)]
    ) async throws {
        try await commit(ScheduleWriteBuilder.scheduleColumnsPlan(
            scheduleId: scheduleId, fields: fields))
    }

    /// Millisecond epoch, the unit `schedules_next_date` timestamps use.
    private static func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// Force immediate sync (pull-to-refresh)
    func syncNow() async {
        logger.info("syncNow() called - forcing immediate sync")
        syncTask?.cancel()
        await performSync()
    }

    /// Recover from a stuck out-of-sync state by discarding the last-synced
    /// marker, then running a sync: the next pass re-requests everything after
    /// the local message log's high-water mark rather than after the last
    /// successful sync. The Merkle tree is deliberately left alone — it is
    /// re-derived from the message log on the next sync anyway, and blanking it
    /// used to hand `fullSync` an excuse to adopt the server's tree and declare
    /// parity it hadn't earned (#99, #121).
    func resetSyncState() async {
        logger.notice("resetSyncState() - clearing lastSyncedTimestamp")
        syncTask?.cancel()
        lastSyncedTimestamp = nil
        retryDelay = 5
        try? saveClock()
        await performSync()
    }

    /// Automatic sync with rate limiting (for foreground events, after transaction creation, etc.)
    /// Skips sync if last successful sync was less than 1 second ago
    /// - Returns: whether the data is freshly synced — true when this call's
    ///   sync succeeded, and also on the rate-limited skip, which by
    ///   construction only fires when a sync SUCCEEDED within the window
    ///   (`shouldSkipAutomaticSync` reads `lastSuccessfulSyncTime`).
    @discardableResult
    func automaticSync() async -> Bool {
        if shouldSkipAutomaticSync() {
            logger.debug("automaticSync() skipped - rate limited (last sync < 1s ago, nothing new locally)")
            return true
        }
        logger.debug("automaticSync() proceeding with sync")
        return await performSync()
    }

    /// Start `automaticSync()` in the background and return immediately.
    ///
    /// Every write path commits its rows and CRDT messages *before* calling
    /// this, so pushing them is catch-up work the writer must not wait on.
    /// Awaiting it here made adding a transaction hang for the whole
    /// URLSession timeout (30s per request) whenever the server was
    /// unreachable, because the UI awaits the write all the way down from the
    /// save button (issue #125). Failures still reach `stateSubject` and the
    /// retry ladder exactly as before.
    ///
    /// Writes that arrive while a push is in flight coalesce onto a single
    /// trailing push: a burst (split save, Wallet import) doesn't stampede the
    /// server, and messages written mid-push still go out.
    private func scheduleAutomaticSync() {
        guard pushTask == nil else {
            logger.debug("scheduleAutomaticSync() - push in flight, coalescing onto a trailing sync")
            pushNeededAfterCurrent = true
            return
        }
        startPushTask(rateLimited: true)
    }

    /// Callers that may be suspended right after writing (App Intents run
    /// headless and can be frozen as soon as they return their result) await
    /// this so the deferred push still gets its chance. Drains trailing pushes
    /// too — `finishPushTask` has already swapped `pushTask` by the time a
    /// task's `value` returns.
    func flushPendingSync() async {
        while let pushTask {
            await pushTask.value
        }
    }

    /// Whether local writes are still waiting to reach the server. Call after
    /// `flushPendingSync()` to find out whether the push actually landed —
    /// pushes are detached, so a write path can't return that answer itself
    /// (issue #139).
    func hasPendingLocalWrites() -> Bool {
        hasUnsyncedLocalMessages()
    }

    private func startPushTask(rateLimited: Bool) {
        pushNeededAfterCurrent = false
        // Assigned synchronously on the actor, so the body can't observe a
        // stale `pushTask` before this returns.
        pushTask = Task {
            if rateLimited {
                await automaticSync()
            } else {
                // This push exists *because* new local messages landed during
                // the previous one, so the 1s rate limiter must not swallow it.
                await performSync()
            }
            finishPushTask()
        }
    }

    private func finishPushTask() {
        pushTask = nil
        if pushNeededAfterCurrent {
            logger.debug("finishPushTask() - running the coalesced trailing sync")
            startPushTask(rateLimited: false)
        }
    }

    // MARK: - Sync Logic

    /// Returns true if automatic sync should be skipped due to rate limiting.
    ///
    /// The window only ever suppresses a redundant *pull* — several foreground
    /// triggers landing at once. It must never suppress a *push*: a skipped
    /// sync drops the local write until something else syncs, and in the
    /// headless Shortcuts/App Intent path nothing else does before the process
    /// is suspended. `LogTransactionIntent` awaits `ensureBudgetReady()`, which
    /// ends in the launch `syncOnForeground()`, so the Wallet write always
    /// landed inside the window and only reached the server the next time the
    /// app was opened (issue #139).
    private func shouldSkipAutomaticSync() -> Bool {
        guard let lastSync = lastSuccessfulSyncTime else {
            return false  // No previous sync, allow it
        }
        guard Date().timeIntervalSince(lastSync) < 1.0 else {
            return false  // Outside the window
        }
        return !hasUnsyncedLocalMessages()
    }

    /// True when messages_crdt holds a message the last successful sync didn't
    /// cover. HLC timestamps are fixed-width and sort lexicographically, so the
    /// high-water mark comparison is exact.
    private func hasUnsyncedLocalMessages() -> Bool {
        guard let database else { return false }
        guard let maxTimestamp = try? database.getMaxMessageTimestamp(), !maxTimestamp.isEmpty else {
            return false  // Nothing recorded locally, nothing to push
        }
        guard let lastSynced = lastSyncedTimestamp, !lastSynced.isEmpty else {
            return true  // Never reconciled — assume there's something to send
        }
        return maxTimestamp > lastSynced
    }

    /// - Returns: true iff the sync completed successfully.
    @discardableResult
    private func performSync() async -> Bool {
        logger.info("performSync() starting...")
        stateSubject.send(.syncing)

        do {
            try await fullSync(since: nil, attemptCount: 0)
            logger.info("performSync() completed successfully")
            stateSubject.send(.idle)
            retryDelay = 5  // reset on success
            lastSuccessfulSyncTime = Date()
            return true
        } catch SyncError.offline {
            logger.notice("performSync() failed - offline")
            stateSubject.send(.offline)
            scheduleRetry()
            return false
        } catch {
            logger.error("performSync() failed: \(error.localizedDescription, privacy: .public)")
            stateSubject.send(.error(error.localizedDescription))
            scheduleRetry()
            return false
        }
    }

    private func fullSync(since: String?, attemptCount: Int) async throws {
        guard let database, let fileId, let groupId else {
            logger.error("fullSync() - not configured!")
            throw SyncError.notConfigured
        }

        logger.debug("fullSync() attempt #\(attemptCount, privacy: .public), since: \(since ?? "nil", privacy: .public), lastSynced: \(self.lastSyncedTimestamp ?? "nil", privacy: .public)")

        // The merkle must describe our own message log and nothing else: a
        // mismatch with the server's tree is the ONLY signal that we're missing
        // messages, so a tree claiming more than we hold makes the missing
        // window unreachable. Two ways the persisted tree drifts from the log:
        //
        //  - an older build overwrote it with the server's tree whenever the
        //    first sync had no lastSyncedTimestamp, recording parity for
        //    messages sync had skipped (#99). The lie is self-consistent — both
        //    sides then fold in the same new messages — so every later diff
        //    matched and the gap survived re-syncs and app updates, leaving
        //    balances stuck at stale, usually higher, amounts (#121).
        //  - `receiveMessages` commits to messages_crdt but the tree is only
        //    persisted at the end of a successful pass, so being killed in
        //    between drops timestamps from the tree that the log kept.
        //
        // Re-deriving from the log before the first comparison of a session
        // repairs both, and the diff recursion below then heals the data. One
        // pass over the log per session, one trie walk per active minute.
        if !hasDerivedMerkleFromLog {
            hasDerivedMerkleFromLog = true
            do {
                let derived = try database.deriveMerkleFromMessageLog()
                if derived.root.hash != merkle.root.hash {
                    logger.notice("Merkle disagreed with the message log (persisted \(self.merkle.root.hash, privacy: .public), derived \(derived.root.hash, privacy: .public)) - re-deriving")
                    merkle = derived
                }
            } catch {
                // Keep the persisted tree: a sync with a possibly stale merkle
                // still beats no sync at all.
                logger.warning("Could not derive merkle from message log: \(error, privacy: .public)")
            }
        }

        // Determine sync starting point
        // Use provided 'since', then lastSyncedTimestamp (if non-empty), then fallback
        let effectiveLastSynced = lastSyncedTimestamp.flatMap { $0.isEmpty ? nil : $0 }
        let sinceTimestamp: String
        if let since = since {
            sinceTimestamp = since
        } else if let lastSynced = effectiveLastSynced {
            sinceTimestamp = lastSynced
        } else if let baseline = downloadBaselineTimestamp, !baseline.isEmpty {
            // No valid lastSynced (fresh download, or reset sync state). The
            // downloaded snapshot's message high-water mark is the true sync
            // floor: everything the server has after it is missing locally no
            // matter how old. A fabricated recent window here (formerly 24h)
            // silently skipped every message between an older file snapshot
            // and yesterday (issue #99).
            logger.notice("No valid lastSyncedTimestamp, using snapshot high-water mark")
            sinceTimestamp = baseline
        } else {
            // No local messages at all — ask for the server's entire message
            // log, which only spans back to the file's last upload/reset.
            logger.notice("No valid lastSyncedTimestamp and empty message log, requesting full server log")
            sinceTimestamp = HLCTimestamp.zero.toString()
        }

        logger.debug("Using sinceTimestamp: \(sinceTimestamp, privacy: .public)")

        // Get local messages to send. On recursion this starts from the merkle
        // diff point, so the server also receives local messages older than
        // lastSyncedTimestamp that it turned out to be missing (matches
        // upstream fullSync, which sends getMessagesSince(since)).
        let localMessages: [CRDTMessage]
        if since != nil || effectiveLastSynced != nil {
            localMessages = try database.getMessagesSince(sinceTimestamp)
        } else {
            // Fresh download / no valid lastSynced, so there's no last-synced
            // window to send from. Send everything newer than the download
            // baseline (the server's high-water mark captured at load); those
            // are genuine local writes made after download, and a write made
            // before the first sync completes would otherwise sit unsent until
            // something else changed it (actios-4k4). The baseline keeps us from
            // re-pushing the entire downloaded history.
            let baseline = downloadBaselineTimestamp ?? ""
            localMessages = try database.getMessagesSince(baseline)
            logger.debug("No valid lastSynced - sending \(localMessages.count, privacy: .public) local message(s) since download baseline")
        }
        logger.debug("Found \(localMessages.count, privacy: .public) local messages to send")

        // Encode request
        let requestData = try encoder.encode(
            messages: localMessages,
            fileId: fileId,
            groupId: groupId,
            keyId: encryptKeyId,
            since: sinceTimestamp
        )
        logger.debug("Encoded request: \(requestData.count, privacy: .public) bytes")

        // POST to server
        logger.debug("Posting sync request to server...")
        let responseData = try await serverClient.postSync(requestData)
        logger.debug("Received response: \(responseData.count, privacy: .public) bytes")

        // Decode response
        let (remoteMessages, remoteMerkle) = try encoder.decode(responseData)
        logger.debug("Decoded \(remoteMessages.count, privacy: .public) remote messages, merkle hash: \(remoteMerkle.hash, privacy: .public)")

        // Apply remote messages
        if !remoteMessages.isEmpty {
            logger.debug("Applying \(remoteMessages.count, privacy: .public) remote messages...")
            try await receiveMessages(remoteMessages)
        }

        // Check if in sync
        let remoteMerkleTree = MerkleTree(root: remoteMerkle)
        logger.debug("Local merkle hash: \(self.merkle.root.hash, privacy: .public), remote: \(remoteMerkle.hash, privacy: .public)")

        if let diffTime = merkle.diff(with: remoteMerkleTree) {
            // Not in sync - recurse from divergence point. This is the only way
            // a missing window is ever recovered, so it runs no matter how the
            // sync state got here: an older build short-circuited it whenever
            // lastSyncedTimestamp was nil and adopted the server's tree
            // instead, which recorded parity we hadn't earned and made the gap
            // permanent (#99, #121). The merkle is derived from our own message
            // log above, so the divergence point is real and each pass narrows
            // it; `attemptCount` still bounds a pathological case.
            logger.debug("Merkle diff found at time: \(diffTime, privacy: .public), recursing...")

            guard attemptCount < 10 else {
                logger.error("Too many sync attempts, giving up")
                throw SyncError.outOfSync
            }
            let diffTimestamp = HLCTimestamp(millis: diffTime, counter: 0, node: "0").toString()
            try await fullSync(since: diffTimestamp, attemptCount: attemptCount + 1)
        } else {
            // Fully synced — persist the HLC as the high-water mark (matches
            // upstream, which stores getClock().timestamp). The HLC was seeded
            // from persisted state in configure, so even on a fresh download it
            // can't regress to the epoch and re-push the entire CRDT history.
            //
            // Reentrancy: the assignment and saveClock below run synchronously
            // after the clock read, so a local write can only interleave during
            // `await clock.current`. If its message lands before the read, its
            // timestamp is in the local merkle (and the server's isn't), so the
            // next sync's diff recursion re-sends it; if it lands after, its
            // timestamp is strictly greater than lastSyncedTimestamp and the
            // next sync's since-window sends it. Either way nothing is dropped.
            logger.info("Merkle trees match - fully synced!")
            let current = await clock.current
            lastSyncedTimestamp = current.toString()
            try saveClock()
        }
    }

    private func receiveMessages(_ messages: [CRDTMessage]) async throws {
        guard let database else { throw SyncError.notConfigured }

        logger.debug("receiveMessages() - processing \(messages.count, privacy: .public) messages")

        // Update clock for each received message
        for msg in messages {
            try await clock.receive(msg.timestamp)
        }

        // Filter out already-applied messages
        let newMessages = try database.filterNewMessages(messages)
        logger.debug("After filtering: \(newMessages.count, privacy: .public) new messages to apply")

        // Apply to local DB
        try database.applyMessages(newMessages)
        logger.debug("Applied messages to database")

        // Store in messages_crdt and merkle-insert only what was actually new.
        // The merkle hash is XOR-based, so re-inserting an existing timestamp
        // (server echo, multi-pass recursion, retry) would cancel it out of the
        // trie and force a permanent divergence from the server.
        let insertedMessages = try database.insertMessages(messages)
        for msg in insertedMessages {
            merkle = merkle.inserting(msg.timestamp)
        }
        if !insertedMessages.isEmpty {
            merkle = merkle.pruned()
        }
        logger.debug("Inserted \(insertedMessages.count, privacy: .public)/\(messages.count, privacy: .public) messages, merkle hash: \(self.merkle.root.hash, privacy: .public)")
    }

    // MARK: - Retry Logic

    private func scheduleRetry() {
        syncTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }

            // Exponential backoff: 5s, 10s, 20s, 40s, 80s, 160s, 300s cap
            retryDelay = min(retryDelay * 2, maxRetryDelay)

            await performSync()
        }
    }

    // Synchronous on purpose: callers must be able to persist
    // lastSyncedTimestamp in the same actor-isolated section that computed it,
    // with no suspension point a local write could interleave into.
    private func saveClock() throws {
        guard let database else { return }

        // Persist the sync high-water mark, not the local HLC. clock.current is
        // the last logical event we generated/received, which on a fresh
        // download is the epoch and would poison the next sync.
        let clockRecord = BudgetDatabase.ClockRecord(
            timestamp: lastSyncedTimestamp ?? "",
            merkle: merkle.root
        )
        try database.saveClock(clockRecord)
    }
}

// MARK: - SchedulePostingActions

extension SyncClient: SchedulePostingActions {
    /// Protocol witness — the default argument on
    /// `createTransaction(_:applyRules:)` can't satisfy the requirement, so
    /// forward explicitly. Scheduled posts go through the rules pass, same as
    /// loot-core's post-transaction path. `advanceScheduleNextDate` already
    /// matches the protocol signature directly.
    func createTransaction(_ transaction: Transaction) async throws {
        try await createTransaction(transaction, applyRules: true)
    }
}
