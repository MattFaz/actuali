// Actuali/Actuali/Services/Sync/SyncClient.swift

import Foundation
import Combine
import CryptoKit
import os

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "SyncClient")

enum SyncError: LocalizedError {
    case notConfigured
    case offline
    case outOfSync
    case encodingFailed
    case serverError(String)

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

    // MARK: - Published State (for UI)

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
                    // Leave nil — fullSync's no-lastSynced path adopts the
                    // server's state rather than fabricating a timestamp.
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

    /// Create a transaction (optimistic local-first)
    func createTransaction(_ transaction: Transaction) async throws {
        guard let database else { throw SyncError.notConfigured }

        logger.debug("createTransaction() - id: \(transaction.id, privacy: .private)")

        // 0. Apply user-defined rules (Actual Budget rules table) before insert.
        //    Skip for transfers — upstream runs rules on the transfer leg, but our
        //    transfer flow already builds both legs explicitly and we don't want
        //    rules rewriting the linked payee/account.
        let finalTransaction: Transaction
        if transaction.transferId == nil {
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

        // 4. Sync to push the transaction to the server (rate-limited)
        await automaticSync()
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

        // 3. Sync to push both legs to the server (rate-limited)
        await automaticSync()
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

        // 4. Sync (rate-limited)
        await automaticSync()
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

    /// Force immediate sync (pull-to-refresh)
    func syncNow() async {
        logger.info("syncNow() called - forcing immediate sync")
        syncTask?.cancel()
        await performSync()
    }

    /// Recover from a stuck out-of-sync state by discarding the local Merkle
    /// tree and last-synced marker, then running a sync. The fresh-download
    /// branch in `fullSync` will adopt the server's Merkle tree, which
    /// resolves persistent divergence at the cost of orphaning any local
    /// writes since the last successful sync (callers should warn the user).
    func resetSyncState() async {
        logger.notice("resetSyncState() - clearing local merkle and lastSyncedTimestamp")
        syncTask?.cancel()
        merkle = MerkleTree()
        lastSyncedTimestamp = nil
        retryDelay = 5
        try? saveClock()
        await performSync()
    }

    /// Automatic sync with rate limiting (for foreground events, after transaction creation, etc.)
    /// Skips sync if last successful sync was less than 1 second ago
    func automaticSync() async {
        if shouldSkipAutomaticSync() {
            logger.debug("automaticSync() skipped - rate limited (last sync < 1s ago)")
            return
        }
        logger.debug("automaticSync() proceeding with sync")
        await performSync()
    }

    // MARK: - Sync Logic

    /// Returns true if automatic sync should be skipped due to rate limiting
    private func shouldSkipAutomaticSync() -> Bool {
        guard let lastSync = lastSuccessfulSyncTime else {
            return false  // No previous sync, allow it
        }
        let elapsed = Date().timeIntervalSince(lastSync)
        return elapsed < 1.0  // Skip if less than 1 second since last sync
    }

    private func performSync() async {
        logger.info("performSync() starting...")
        stateSubject.send(.syncing)

        do {
            try await fullSync(since: nil, attemptCount: 0)
            logger.info("performSync() completed successfully")
            stateSubject.send(.idle)
            retryDelay = 5  // reset on success
            lastSuccessfulSyncTime = Date()
        } catch SyncError.offline {
            logger.notice("performSync() failed - offline")
            stateSubject.send(.offline)
            scheduleRetry()
        } catch {
            logger.error("performSync() failed: \(error.localizedDescription, privacy: .public)")
            stateSubject.send(.error(error.localizedDescription))
            scheduleRetry()
        }
    }

    private func fullSync(since: String?, attemptCount: Int) async throws {
        guard let database, let fileId, let groupId else {
            logger.error("fullSync() - not configured!")
            throw SyncError.notConfigured
        }

        logger.debug("fullSync() attempt #\(attemptCount, privacy: .public), since: \(since ?? "nil", privacy: .public), lastSynced: \(self.lastSyncedTimestamp ?? "nil", privacy: .public)")

        // Determine sync starting point
        // Use provided 'since', then lastSyncedTimestamp (if non-empty), then fallback
        let effectiveLastSynced = lastSyncedTimestamp.flatMap { $0.isEmpty ? nil : $0 }
        let sinceTimestamp: String
        if let since = since {
            sinceTimestamp = since
        } else if let lastSynced = effectiveLastSynced {
            sinceTimestamp = lastSynced
        } else {
            // No valid lastSynced - use 24 hours ago to catch recent changes
            // This handles both fresh downloads (merkle=0) and recovered from bad state
            logger.notice("No valid lastSyncedTimestamp, using 24h window")
            sinceTimestamp = HLCTimestamp(
                millis: Int64(Date().addingTimeInterval(-86400).timeIntervalSince1970 * 1000),
                counter: 0,
                node: "0"
            ).toString()
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
            // Fresh download / no valid lastSynced. The local merkle is empty and we
            // adopt the server's below, so merkle-diff recursion can't push local
            // writes for us. Send everything newer than the download baseline (the
            // server's high-water mark captured at load); those are genuine local
            // writes made after download. Without this, a write made before the first
            // sync completes is dropped when we adopt the server merkle and advance
            // lastSynced past it (actios-4k4). The baseline keeps us from re-pushing
            // the entire downloaded history.
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
            // Not in sync - recurse from divergence point
            logger.debug("Merkle diff found at time: \(diffTime, privacy: .public), recursing...")

            // Special case: if we don't have a valid lastSynced, don't recurse.
            // This happens after downloading a budget or recovering from bad state.
            // Instead, adopt the server's merkle and consider ourselves synced.
            if effectiveLastSynced == nil {
                logger.info("No valid lastSynced - adopting server's merkle tree")
                merkle = remoteMerkleTree
                // Advance lastSynced only to what we actually reconciled this pass:
                // the download baseline plus the messages we sent and received. Using
                // this instead of the raw clock high-water mark avoids skipping a
                // local write that interleaved during the awaits above without being
                // included in `localMessages` — such a write sorts above this mark
                // (HLC timestamps order lexicographically) and is resent next sync
                // (actios-4k4). Fall back to the clock only for a truly empty budget
                // with nothing reconciled, so we still record that a sync happened.
                let reconciled = ([downloadBaselineTimestamp]
                    + localMessages.map { $0.timestamp.toString() }
                    + remoteMessages.map { $0.timestamp.toString() })
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .max()
                if let reconciled {
                    lastSyncedTimestamp = reconciled
                } else {
                    lastSyncedTimestamp = (await clock.current).toString()
                }
                logger.debug("Set lastSyncedTimestamp to: \(self.lastSyncedTimestamp ?? "nil", privacy: .public)")
                try saveClock()
                return
            }

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
