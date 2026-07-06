import Foundation
import SwiftUI
import Combine
import os

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "BudgetStore")

/// Errors thrown by `BudgetStore` write operations.
enum BudgetStoreError: LocalizedError, Equatable {
    case syncNotConfigured
    case transferAccountsMatch
    case transferAmountNotPositive
    case transferPayeeMissing
    case invalidAmount
    case missingTransferDestination
    case payeeCreationFailed(String)
    case cannotConvertToTransfer

    var errorDescription: String? {
        switch self {
        case .syncNotConfigured:
            return "Sync not configured"
        case .transferAccountsMatch:
            return "Transfer source and destination must differ"
        case .transferAmountNotPositive:
            return "Transfer amount must be positive"
        case .transferPayeeMissing:
            return "Transfer payee not found for selected accounts"
        case .invalidAmount:
            return "Invalid amount"
        case .missingTransferDestination:
            return "Select a destination account"
        case .payeeCreationFailed(let message):
            return "Failed to create payee: \(message)"
        case .cannotConvertToTransfer:
            return "Can't convert an existing transaction into a transfer"
        }
    }
}

@MainActor
final class BudgetStore: ObservableObject {
    // MARK: - Published State

    @Published var isLoading = false
    @Published var downloadingBudgetId: String?
    /// Global error alert (rendered in ContentView) for background/destructive operation failures (e.g. delete); form-local errors (e.g. saveTransaction validation) stay in the presenting view.
    @Published var error: String?

    @Published var serverURL: String = "" {
        didSet {
            UserDefaults.standard.set(serverURL, forKey: "serverURL")
        }
    }

    @Published var isConnected = false

    /// Login methods advertised by the configured server (populated by
    /// `checkLoginMethods()`). Empty until the server has been probed.
    @Published var availableLoginMethods: [LoginMethod] = []

    /// Whether the server already has an account owner. When false, the first
    /// OpenID sign-in must supply the server password (see `requiresServerPassword`).
    @Published var ownerExists = true

    /// Whether the configured server has a password method at all (active or not).
    var supportsPasswordLogin: Bool {
        availableLoginMethods.contains { $0.method == "password" }
    }

    /// Whether password is the *active* login method — i.e. tapping Connect
    /// should perform a direct password login.
    var passwordLoginActive: Bool {
        availableLoginMethods.contains { $0.method == "password" && $0.isActive }
    }

    /// Whether the configured server offers OpenID/OAuth login.
    var supportsOpenIDLogin: Bool {
        availableLoginMethods.contains { $0.method == "openid" }
    }

    /// Whether the first OpenID sign-in must include the server password: the
    /// server still has a password fallback and no owner has been created yet.
    /// Mirrors the official web client's "Enter server password" prompt.
    var requiresServerPassword: Bool {
        supportsOpenIDLogin && supportsPasswordLogin && !ownerExists
    }

    @Published var currentBudgetId: String? {
        didSet {
            UserDefaults.standard.set(currentBudgetId, forKey: "currentBudgetId")
        }
    }

    @Published var remoteBudgets: [RemoteBudget] = []
    @Published var accounts: [Account] = []
    @Published var transactions: [Transaction] = []
    /// How many transactions still need a category (drives the Budget tab
    /// link to UncategorizedTransactionsView).
    @Published var uncategorizedCount: Int = 0
    @Published var categoryGroups: [CategoryGroup] = []
    @Published var payees: [Payee] = []
    @Published var currentBudgetMonth: BudgetMonth?
    @Published var syncState: SyncState = .idle
    @Published var lastSyncTime: Date?

    /// Currency code for formatting (e.g., "USD", "EUR", "GBP")
    /// Persisted to UserDefaults, defaults to "USD"
    @Published var currencyCode: String = "USD" {
        didSet {
            UserDefaults.standard.set(currencyCode, forKey: "currencyCode")
        }
    }

    /// User-selected appearance (system / light / dark). Persisted to UserDefaults.
    @Published var appearanceMode: AppearanceMode = .system {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: "appearanceMode")
        }
    }

    /// Whether Budget rows show a spent-vs-available progress bar.
    /// Persisted to UserDefaults, defaults to on.
    @Published var showBudgetProgressBars: Bool = true {
        didSet {
            UserDefaults.standard.set(showBudgetProgressBars, forKey: "showBudgetProgressBars")
        }
    }

    // MARK: - User Preferences (per-budget, stored in UserDefaults)

    var defaultAccountId: String? {
        get {
            guard let budgetId = currentBudgetId else { return nil }
            return UserDefaults.standard.string(forKey: "defaultAccountId_\(budgetId)")
        }
        set {
            guard let budgetId = currentBudgetId else { return }
            if let value = newValue {
                UserDefaults.standard.set(value, forKey: "defaultAccountId_\(budgetId)")
            } else {
                UserDefaults.standard.removeObject(forKey: "defaultAccountId_\(budgetId)")
            }
            objectWillChange.send()
        }
    }

    // MARK: - Private

    private let serverClient = ActualServerClient()
    private let fileManager = BudgetFileManager.shared
    private var database: BudgetDatabase?

    /// Read-only accessor for collaborators (e.g. TransactionLogger) that need
    /// direct DB access for queries that don't fit the @Published cache. The
    /// underlying `database` remains private to enforce that writes go through
    /// store methods.
    var databaseForLogger: BudgetDatabase? { database }

    /// Accounts for App Intents (the Log Transaction Shortcut).
    ///
    /// `LogTransactionIntent` runs with `openAppWhenRun = false`, so Shortcuts
    /// can launch the app *headless* to re-resolve the saved account parameter
    /// before the async budget load kicked off in `init()` has populated
    /// `accounts`. Reading the still-empty in-memory array there made the
    /// `AccountEntityQuery` return no match, and Shortcuts reported "Account is
    /// no longer available. Edit your shortcut to pick a different account."
    ///
    /// Fall back to a direct database read when the cache is empty so account
    /// resolution is correct on a cold launch. Returns `[]` only when there is
    /// genuinely no budget/database available.
    /// Ensure the saved budget is fully loaded — specifically that `syncClient`
    /// is created and configured — before a headless write.
    ///
    /// `LogTransactionIntent` runs with `openAppWhenRun = false`, so the app can
    /// be launched headless and reach the write path before the background
    /// `loadLocalBudget` started in `init()` has wired `syncClient`. Writing then
    /// throws `.syncNotConfigured` ("Couldn't save transaction"). Await the
    /// in-flight load here (or start one if none is running) so the write path
    /// sees a fully configured store.
    func ensureBudgetReady() async {
        if syncClient != nil { return }
        if let loadTask {
            await loadTask.value
            return
        }
        // No in-flight load (e.g. a freshly spawned headless process where the
        // init() Task hasn't been retained). Start one and await it.
        guard let budgetId = currentBudgetId, fileManager.budgetExists(budgetId) else { return }
        let task = Task { await loadLocalBudget(budgetId) }
        loadTask = task
        await task.value
    }

    func accountsForIntent() async -> [Account] {
        if !accounts.isEmpty { return accounts }
        do {
            let db: BudgetDatabase
            if let database {
                db = database
            } else if let budgetId = currentBudgetId, fileManager.budgetExists(budgetId) {
                db = try BudgetDatabase(path: fileManager.databasePath(for: budgetId))
            } else {
                return []
            }
            return try await db.fetchAccounts()
        } catch {
            logger.error("accountsForIntent DB fallback failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private var syncClient: SyncClient?
    private var syncStateCancellable: AnyCancellable?

    /// Handle to the in-flight `loadLocalBudget` started in `init()`. App Intents
    /// can run before that background load has wired `syncClient`, so the headless
    /// write path awaits this via `ensureBudgetReady()`.
    private var loadTask: Task<Void, Never>?

    struct RemoteBudget: Identifiable {
        let id: String
        let name: String
        let groupId: String?
        let isEncrypted: Bool
    }

    // MARK: - Initialization

    @MainActor static let shared = BudgetStore()

    /// Builds a fresh ephemeral store for SwiftUI previews. Do NOT use in production code paths;
    /// production must use `BudgetStore.shared` so the database is single-writer.
    static func previewInstance() -> BudgetStore {
        BudgetStore(forPreview: ())
    }

    #if DEBUG
    /// Test-only: wire a database and sync client directly so write paths
    /// (e.g. `saveTransaction`) can be exercised end-to-end without the
    /// file-system and server plumbing in `loadLocalBudget`.
    func configureForTesting(database: BudgetDatabase, syncClient: SyncClient) {
        self.database = database
        self.syncClient = syncClient
    }
    #endif

    private init() {
        // Restore saved state
        serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        currentBudgetId = UserDefaults.standard.string(forKey: "currentBudgetId")
        currencyCode = UserDefaults.standard.string(forKey: "currencyCode") ?? "USD"
        if let raw = UserDefaults.standard.string(forKey: "appearanceMode"),
           let mode = AppearanceMode(rawValue: raw) {
            appearanceMode = mode
        }
        showBudgetProgressBars = UserDefaults.standard
            .object(forKey: "showBudgetProgressBars") as? Bool ?? true

        let token = loadAndMigrateAuthToken()

        // Load local budget if available. The saved session is configured in
        // the same task, before the load, so the initial sync below is
        // authenticated.
        if let budgetId = currentBudgetId, fileManager.budgetExists(budgetId) {
            loadTask = Task {
                if let token { await configureSavedSession(token: token) }
                await loadLocalBudget(budgetId)
                // On a cold launch the scene becomes .active before
                // loadLocalBudget has wired syncClient, so the scenePhase
                // foreground sync no-ops. Sync here once the client exists.
                await syncOnForeground()
            }
        } else if let token {
            Task { await configureSavedSession(token: token) }
        }
    }

    /// Configure server URL and token for sync to work on launch and app resume
    private func configureSavedSession(token: String) async {
        try? await serverClient.configure(serverURL: serverURL)
        await serverClient.setToken(token)
        isConnected = true
    }

    private init(forPreview: Void) {
        // Empty preview store — no UserDefaults reads, no auto-load.
    }

    // MARK: - Server Connection

    func connect() async {
        let normalized = Self.normalizedServerURL(serverURL)
        guard !normalized.isEmpty else {
            error = "Please enter a server URL"
            return
        }
        if normalized != serverURL {
            serverURL = normalized
        }

        isLoading = true
        error = nil

        do {
            try await serverClient.configure(serverURL: normalized)
        } catch {
            self.error = error.localizedDescription
            isLoading = false
            return
        }

        isLoading = false
    }

    /// Trims whitespace and prepends `https://` if the user omitted a scheme.
    /// Empty input stays empty so callers can still detect "missing URL".
    static func normalizedServerURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.range(of: "^[A-Za-z][A-Za-z0-9+\\-.]*://", options: .regularExpression) != nil {
            return trimmed
        }
        return "https://" + trimmed
    }

    func login(password: String) async {
        isLoading = true
        error = nil

        do {
            let token = try await serverClient.login(password: password)
            try? Keychain.set(token, for: "authToken")
            isConnected = true
            await fetchRemoteBudgets()
        } catch {
            self.error = error.localizedDescription
            isConnected = false
        }

        isLoading = false
    }

    /// Probe the configured server for its available login methods so the UI can
    /// offer password and/or OpenID sign-in. Best-effort: on failure we fall back
    /// to password-only so the existing flow keeps working.
    func checkLoginMethods() async {
        do {
            availableLoginMethods = try await serverClient.fetchLoginMethods()
        } catch {
            logger.error("Failed to fetch login methods: \(error.localizedDescription, privacy: .public)")
            availableLoginMethods = [LoginMethod(method: "password", displayName: "Password", active: 1)]
        }
        // Only relevant when OpenID is offered; cheap enough to always refresh.
        if supportsOpenIDLogin {
            ownerExists = await serverClient.fetchOwnerCreated()
        }
    }

    /// Run the OpenID/OAuth browser sign-in flow end to end: ask the server for
    /// an authorization URL, present it via `ASWebAuthenticationSession`, then
    /// persist the returned token exactly like a password login.
    /// - Parameter firstTimePassword: only needed when the server also has
    ///   password auth and no users exist yet (first login).
    func loginWithOpenID(firstTimePassword: String?) async {
        isLoading = true
        error = nil

        do {
            let authURL = try await serverClient.beginOpenIDLogin(
                returnURL: OpenIDAuthenticator.returnURL,
                firstTimePassword: firstTimePassword
            )
            let authenticator = OpenIDAuthenticator()
            let token = try await authenticator.authenticate(authorizationURL: authURL)

            await serverClient.setToken(token)
            try? Keychain.set(token, for: "authToken")
            isConnected = true
            await fetchRemoteBudgets()
        } catch OpenIDAuthError.cancelled {
            // User dismissed the browser sheet — not an error worth surfacing.
        } catch {
            self.error = error.localizedDescription
            isConnected = false
        }

        isLoading = false
    }

    func logout() {
        Task {
            await serverClient.setToken(nil)
        }
        try? Keychain.remove(for: "authToken")
        // Defensively remove any legacy UserDefaults copy
        UserDefaults.standard.removeObject(forKey: "authToken")
        isConnected = false
        remoteBudgets = []
        // Re-probe on the next connection in case the server URL changes.
        availableLoginMethods = []
        ownerExists = true
    }

    /// Load the auth token, migrating from UserDefaults to Keychain on first run.
    private func loadAndMigrateAuthToken() -> String? {
        if let token = Keychain.get(for: "authToken") {
            return token
        }
        if let legacyToken = UserDefaults.standard.string(forKey: "authToken") {
            try? Keychain.set(legacyToken, for: "authToken")
            UserDefaults.standard.removeObject(forKey: "authToken")
            return legacyToken
        }
        return nil
    }

    // MARK: - Budget Management

    func fetchRemoteBudgets() async {
        isLoading = true
        error = nil

        do {
            let files = try await serverClient.listFiles()
            remoteBudgets = files.map { file in
                RemoteBudget(
                    id: file.fileId,
                    name: file.name,
                    groupId: file.groupId,
                    isEncrypted: file.encryptKeyId != nil
                )
            }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    func downloadBudget(_ remoteBudget: RemoteBudget) async {
        isLoading = true
        downloadingBudgetId = remoteBudget.id
        error = nil

        // Close existing database before importing (prevents "vnode unlinked" error)
        syncStateCancellable?.cancel()
        syncStateCancellable = nil
        syncClient = nil
        database = nil

        do {
            var loadedKey: LoadedKey?
            if remoteBudget.isEncrypted {
                guard let key = EncryptionKeyManager.load(fileId: remoteBudget.id) else {
                    self.error = "This budget is encrypted. Enter its encryption password to open it."
                    isLoading = false
                    downloadingBudgetId = nil
                    return
                }
                loadedKey = key
            }

            // Download the (possibly encrypted) ZIP blob.
            var zipData = try await serverClient.downloadFile(fileId: remoteBudget.id)

            // Decrypt the whole blob for encrypted budgets.
            if let loadedKey {
                let info = try await serverClient.getFileInfo(fileId: remoteBudget.id)
                guard let meta = info.encryptMeta else {
                    throw ActualServerError.invalidResponse
                }
                guard meta.keyId == loadedKey.keyId else {
                    try? EncryptionKeyManager.remove(fileId: remoteBudget.id)
                    self.error = "This budget's encryption key has changed. Re-enter the password."
                    isLoading = false
                    downloadingBudgetId = nil
                    return
                }
                guard let iv = meta.iv, let authTag = meta.authTag else {
                    throw ActualServerError.invalidResponse
                }
                zipData = try SyncEncryption.decrypt(
                    ciphertext: zipData, ivBase64: iv, authTagBase64: authTag, using: loadedKey.key
                )
            }

            let metadata = try await fileManager.importBudget(
                from: zipData, fileId: remoteBudget.id, groupId: remoteBudget.groupId
            )
            currentBudgetId = metadata.id
            await loadLocalBudget(metadata.id)
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
        downloadingBudgetId = nil
    }

    /// Validate an encryption password for a budget, persist the derived key, then download it.
    /// Returns nil on success, or a user-facing error message on failure (so the sheet can stay open).
    func unlockAndOpen(_ remoteBudget: RemoteBudget, password: String) async -> String? {
        do {
            let keyInfo = try await serverClient.getKeyInfo(fileId: remoteBudget.id)
            let loaded = try EncryptionKeyManager.deriveAndValidate(password: password, keyInfo: keyInfo)
            try EncryptionKeyManager.store(loaded, fileId: remoteBudget.id)
        } catch let e as EncryptionKeyError {
            return e.errorDescription
        } catch {
            return error.localizedDescription
        }
        await downloadBudget(remoteBudget)
        return error   // any download error surfaced by downloadBudget
    }

    func loadLocalBudget(_ budgetId: String) async {
        isLoading = true
        error = nil

        var db: BudgetDatabase?
        do {
            let dbPath = fileManager.databasePath(for: budgetId)
            let openedDb = try BudgetDatabase(path: dbPath)
            db = openedDb
            database = openedDb

            // Fetch all data into locals first, then publish in one batch so
            // the UI never sees a torn snapshot if another load interleaves
            // at a suspension point.
            // Currency code from preferences (use if non-empty, else keep UserDefaults value)
            let fetchedCurrencyCode = try await openedDb.fetchCurrencyCode()
            let fetchedAccounts = try await openedDb.fetchAccounts()
            let fetchedTransactions = try await openedDb.fetchTransactions()
            let fetchedUncategorizedCount = try await openedDb.fetchUncategorizedCount()
            let fetchedGroups = try await openedDb.fetchCategoryGroups()
            let fetchedPayees = try await openedDb.fetchPayees()
            let currentMonth = currentMonthString()
            let fetchedBudgetMonth = try await openedDb.fetchBudgetMonth(month: currentMonth)

            // If a concurrent load replaced the database while we were
            // fetching (e.g. demo seed during launch), drop our stale snapshot.
            // Return without touching isLoading — the winning load owns the
            // spinner and clears it when it finishes.
            guard database === openedDb else { return }

            if let code = fetchedCurrencyCode, !code.isEmpty {
                currencyCode = code
            }
            accounts = fetchedAccounts
            transactions = fetchedTransactions
            uncategorizedCount = fetchedUncategorizedCount
            categoryGroups = fetchedGroups
            payees = fetchedPayees
            currentBudgetMonth = fetchedBudgetMonth

            // Configure sync client
            let nodeId = UserDefaults.standard.string(forKey: "nodeId") ?? {
                let id = HybridLogicalClock.generateNodeId()
                UserDefaults.standard.set(id, forKey: "nodeId")
                return id
            }()

            syncClient = SyncClient(serverClient: serverClient, nodeId: nodeId)

            // Get file metadata for groupId
            // Note: budgetId is the internal ID (from metadata.json), but remoteBudgets uses server fileId
            // So we need to load the local metadata to get the cloudFileId for lookup
            let metadataPath = fileManager.metadataPath(for: budgetId)
            var groupId: String = ""
            var fileId: String = budgetId

            if let metadataData = try? Data(contentsOf: metadataPath),
               let metadata = try? JSONDecoder().decode(BudgetMetadata.self, from: metadataData) {
                fileId = metadata.cloudFileId ?? budgetId
                groupId = metadata.groupId ?? ""
                logger.info("Configuring sync with fileId: \(fileId, privacy: .private), groupId: \(groupId, privacy: .private)")
            } else {
                logger.notice("Could not load metadata for budget \(budgetId, privacy: .private)")
            }

            if let db = database {
                let loadedKey = EncryptionKeyManager.load(fileId: fileId)
                try await syncClient?.configure(
                    database: db,
                    fileId: fileId,
                    groupId: groupId,
                    encryptionKey: loadedKey?.key,
                    keyId: loadedKey?.keyId
                )
                logger.info("Sync configuration successful (encrypted: \(loadedKey != nil, privacy: .public))")
            } else {
                logger.error("Database is nil, cannot configure sync")
            }

            // Subscribe to sync state
            syncStateCancellable = syncClient?.statePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    self?.syncState = state
                }

        } catch {
            // If a concurrent load replaced our database mid-fetch, this
            // failure belongs to a stale load — don't clobber the winner's
            // error or clear its spinner.
            guard db == nil || database === db else { return }
            self.error = "Failed to load budget: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func refreshData() async {
        guard let budgetId = currentBudgetId else { return }
        await loadLocalBudget(budgetId)
    }

    /// Populate a local "demo" budget with curated data, for screenshots and for
    /// letting users (and App Review) explore the app without configuring a server.
    /// Logs out any active server session so sync cannot fire against a real server.
    func loadDemoData() async {
        // Log out any active session so sync doesn't try to fire against a real server
        logout()
        do {
            try DemoDataSeeder.seed()
            currentBudgetId = DemoDataSeeder.budgetId
            await loadLocalBudget(DemoDataSeeder.budgetId)
            // The seeder recreates the budget directory mid-launch, so any
            // loadLocalBudget already running from init() may have captured an
            // I/O error. A successful demo seed supersedes it.
            self.error = nil
        } catch {
            self.error = "Failed to seed demo data: \(error.localizedDescription)"
        }
    }

    /// Refresh just the data without recreating SyncClient
    /// Use this after local changes to update the UI
    private func refreshDataOnly() async {
        guard let database else { return }
        do {
            // Fetch into locals, then publish in one batch (no suspension
            // points between assignments) so overlapping refreshes can't
            // leave the UI with a mixed snapshot.
            let fetchedAccounts = try await database.fetchAccounts()
            let fetchedTransactions = try await database.fetchTransactions()
            let fetchedUncategorizedCount = try await database.fetchUncategorizedCount()
            let fetchedGroups = try await database.fetchCategoryGroups()
            let fetchedPayees = try await database.fetchPayees()
            let currentMonth = currentMonthString()
            let fetchedBudgetMonth = try await database.fetchBudgetMonth(month: currentMonth)

            // If the budget was switched while we were fetching, this
            // snapshot belongs to the old database — drop it.
            guard self.database === database else { return }

            accounts = fetchedAccounts
            transactions = fetchedTransactions
            uncategorizedCount = fetchedUncategorizedCount
            categoryGroups = fetchedGroups
            payees = fetchedPayees
            currentBudgetMonth = fetchedBudgetMonth
        } catch {
            // If the budget was switched mid-fetch, the failure belongs to
            // the old database — don't surface it over the new budget.
            guard self.database === database else { return }
            self.error = "Failed to refresh data: \(error.localizedDescription)"
        }
    }

    // MARK: - Payees

    /// Find an existing payee by name (case-insensitive) or create a new one
    func findOrCreatePayee(name: String) async throws -> Payee {
        // Look for existing payee (case-insensitive)
        if let existing = payees.first(where: { $0.name.lowercased() == name.lowercased() }) {
            return existing
        }

        // Create new payee
        let newPayee = Payee(
            id: UUID().uuidString,
            name: name,
            transferAccountId: nil,
            tombstone: false
        )

        guard let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }

        try await syncClient.createPayee(newPayee)

        // Add to local list immediately (optimistic)
        payees.append(newPayee)

        return newPayee
    }

    // MARK: - Transactions

    func fetchTransactions(for accountId: String) async -> [Transaction] {
        do {
            return try await database?.fetchTransactions(accountId: accountId) ?? []
        } catch {
            self.error = error.localizedDescription
            return []
        }
    }

    /// All transactions still needing a category (see
    /// BudgetDatabase.fetchUncategorizedTransactions for the exact filter).
    func fetchUncategorizedTransactions() async -> [Transaction] {
        do {
            return try await database?.fetchUncategorizedTransactions() ?? []
        } catch {
            self.error = error.localizedDescription
            return []
        }
    }

    /// Create a new transaction (optimistic local-first)
    func createTransaction(_ transaction: Transaction) async throws {
        guard let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }

        try await syncClient.createTransaction(transaction)

        // Refresh local data (without recreating SyncClient, which would cancel the scheduled sync)
        await refreshDataOnly()
    }

    /// Create a paired transfer between two accounts. Writes both legs with linked
    /// `transferId`s and uses the existing transfer payee for each side.
    /// - Parameters:
    ///   - fromAccountId: account the money leaves (negative leg)
    ///   - toAccountId: account the money arrives in (positive leg)
    ///   - amountCents: positive cents amount
    ///   - date: YYYYMMDD
    ///   - notes: shared notes (applied to both legs)
    ///   - cleared: applied to both legs
    func createTransfer(
        fromAccountId: String,
        toAccountId: String,
        amountCents: Int,
        date: Int,
        notes: String?,
        cleared: Bool
    ) async throws {
        guard let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }
        guard fromAccountId != toAccountId else {
            throw BudgetStoreError.transferAccountsMatch
        }
        guard amountCents > 0 else {
            throw BudgetStoreError.transferAmountNotPositive
        }

        let fromTransferPayee = transferPayee(forAccountId: fromAccountId)
        let toTransferPayee = transferPayee(forAccountId: toAccountId)
        guard let fromTransferPayee, let toTransferPayee else {
            throw BudgetStoreError.transferPayeeMissing
        }

        let sourceId = UUID().uuidString
        let targetId = UUID().uuidString

        let source = Transaction(
            id: sourceId,
            accountId: fromAccountId,
            date: date,
            amount: -amountCents,
            payeeId: toTransferPayee.id,
            payeeName: toTransferPayee.name,
            categoryId: nil,
            categoryName: nil,
            notes: notes,
            cleared: cleared,
            reconciled: false,
            transferId: targetId,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: nil,
            importedPayee: nil
        )

        let target = Transaction(
            id: targetId,
            accountId: toAccountId,
            date: date,
            amount: amountCents,
            payeeId: fromTransferPayee.id,
            payeeName: fromTransferPayee.name,
            categoryId: nil,
            categoryName: nil,
            notes: notes,
            cleared: cleared,
            reconciled: false,
            transferId: sourceId,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: nil,
            importedPayee: nil
        )

        try await syncClient.createTransfer(source: source, target: target)
        await refreshDataOnly()
    }

    private func transferPayee(forAccountId accountId: String) -> Payee? {
        payees.first { $0.transferAccountId == accountId && !$0.tombstone }
    }

    /// Update an existing transaction (optimistic local-first)
    func updateTransaction(_ updated: Transaction, original: Transaction) async throws {
        guard let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }

        let changedFields = Self.changedFields(original: original, updated: updated)
        try await syncClient.updateTransaction(updated, changedFields: changedFields)
        await refreshDataOnly()
    }

    /// Soft-delete a transaction by setting its tombstone flag (CRDT-compatible).
    /// Failures surface through the published `error` string.
    func deleteTransaction(_ transaction: Transaction) async {
        do {
            guard let syncClient else {
                throw BudgetStoreError.syncNotConfigured
            }
            var deleted = transaction
            deleted.tombstone = true
            try await syncClient.updateTransaction(deleted, changedFields: ["tombstone"])
        } catch {
            self.error = "Failed to delete transaction: \(error.localizedDescription)"
            return
        }
        await refreshDataOnly()
    }

    // MARK: - Transaction Form

    /// Input gathered by the add/edit transaction form (`AddTransactionView`).
    /// `amount` is the raw field text, always unsigned — `type` determines
    /// the sign and whether the save is a transfer.
    struct TransactionForm {
        var accountId: String
        var type: TransactionType
        var amount: String
        var payeeName: String
        var transferToAccountId: String?
        var categoryId: String?
        var notes: String
        var date: Date
        var cleared: Bool
    }

    /// The store-side action a form resolves to. Validation and routing are
    /// pure so they can be tested without a configured sync client.
    enum TransactionFormPlan: Equatable {
        case transfer(toAccountId: String, amountCents: Int)
        case standard(amountCents: Int)
    }

    static func plan(for form: TransactionForm) throws -> TransactionFormPlan {
        guard let dollars = Double(form.amount),
              let unsignedCents = Transaction.cents(fromDollars: dollars) else {
            throw BudgetStoreError.invalidAmount
        }
        switch form.type {
        case .transfer:
            guard let toAccountId = form.transferToAccountId else {
                throw BudgetStoreError.missingTransferDestination
            }
            return .transfer(toAccountId: toAccountId, amountCents: unsignedCents)
        case .expense:
            return .standard(amountCents: -unsignedCents)
        case .income:
            return .standard(amountCents: unsignedCents)
        }
    }

    /// Save the add/edit form: transfers become a paired transfer, everything
    /// else resolves its payee and creates or (when `original` is non-nil)
    /// updates the transaction.
    func saveTransaction(_ form: TransactionForm, editing original: Transaction? = nil) async throws {
        let date = Transaction.yyyymmdd(from: form.date)
        let notes = form.notes.isEmpty ? nil : form.notes

        switch try Self.plan(for: form) {
        case .transfer(let toAccountId, let amountCents):
            // Editing into a transfer would create a new transfer pair and orphan
            // the original transaction (the UI hides the Transfer option when
            // editing; this guards the path against state edge cases). Refuse
            // rather than silently corrupt. See actios-7u6.
            guard original == nil else {
                throw BudgetStoreError.cannotConvertToTransfer
            }
            try await createTransfer(
                fromAccountId: form.accountId,
                toAccountId: toAccountId,
                amountCents: amountCents,
                date: date,
                notes: notes,
                cleared: form.cleared
            )

        case .standard(let amountCents):
            let payeeId = try await resolvePayeeId(name: form.payeeName, editing: original)
            let payeeName = form.payeeName.isEmpty ? nil : form.payeeName

            if let original {
                let updated = Transaction(
                    id: original.id,
                    accountId: form.accountId,
                    date: date,
                    amount: amountCents,
                    payeeId: payeeId,
                    payeeName: payeeName,
                    categoryId: form.categoryId,
                    categoryName: nil,
                    notes: notes,
                    cleared: form.cleared,
                    reconciled: original.reconciled,
                    transferId: original.transferId,
                    isParent: original.isParent,
                    parentId: original.parentId,
                    tombstone: original.tombstone,
                    sortOrder: original.sortOrder
                )
                try await updateTransaction(updated, original: original)
            } else {
                let transaction = Transaction(
                    id: UUID().uuidString,
                    accountId: form.accountId,
                    date: date,
                    amount: amountCents,
                    payeeId: payeeId,
                    payeeName: payeeName,
                    categoryId: form.categoryId,
                    categoryName: nil,
                    notes: notes,
                    cleared: form.cleared,
                    reconciled: false,
                    transferId: nil,
                    isParent: false,
                    parentId: nil,
                    tombstone: false,
                    sortOrder: nil,  // Set to Date.now() during insert
                    importedPayee: payeeName
                )
                try await createTransaction(transaction)
            }
        }
    }

    /// Payee id for a standard (non-transfer) save: an empty name clears the
    /// payee, a name unchanged from the transaction being edited keeps it,
    /// and anything else is matched case-insensitively or created.
    func resolvePayeeId(name: String, editing original: Transaction?) async throws -> String? {
        if name.isEmpty { return nil }
        if name == original?.payeeName { return original?.payeeId }
        do {
            return try await findOrCreatePayee(name: name).id
        } catch {
            throw BudgetStoreError.payeeCreationFailed(error.localizedDescription)
        }
    }

    private static func changedFields(original: Transaction, updated: Transaction) -> Set<String> {
        var changed = Set<String>()
        if original.accountId != updated.accountId { changed.insert("acct") }
        if original.date != updated.date { changed.insert("date") }
        if original.payeeId != updated.payeeId { changed.insert("description") }
        if original.categoryId != updated.categoryId { changed.insert("category") }
        if original.amount != updated.amount { changed.insert("amount") }
        if original.notes != updated.notes { changed.insert("notes") }
        if original.cleared != updated.cleared { changed.insert("cleared") }
        if original.reconciled != updated.reconciled { changed.insert("reconciled") }
        if original.transferId != updated.transferId { changed.insert("transferred_id") }
        if original.isParent != updated.isParent { changed.insert("isParent") }
        if original.parentId != updated.parentId { changed.insert("parent_id") }
        if original.tombstone != updated.tombstone { changed.insert("tombstone") }
        return changed
    }

    // MARK: - Sync

    /// Force immediate sync
    func sync() async {
        logger.info("sync() called")
        if syncClient == nil {
            logger.notice("syncClient is nil, cannot sync!")
        }
        await syncClient?.syncNow()
        lastSyncTime = Date()
        logger.debug("sync() completed, refreshing data...")
        await refreshDataOnly()
    }

    /// Discard local sync state and re-adopt the server's Merkle tree.
    /// Used to recover when the client is stuck in a divergent state.
    func resetSyncState() async {
        logger.notice("resetSyncState() called from BudgetStore")
        await syncClient?.resetSyncState()
        lastSyncTime = Date()
        await refreshDataOnly()
    }

    /// Sync when app enters foreground - only if a budget is loaded
    /// Uses rate-limited automatic sync to avoid redundant syncs
    func syncOnForeground() async {
        guard let client = syncClient else {
            logger.debug("syncOnForeground() skipped - no budget loaded")
            return
        }
        logger.info("syncOnForeground() - app became active, syncing...")
        await client.automaticSync()
        lastSyncTime = Date()
        await refreshDataOnly()
    }

    // MARK: - Budget

    /// Most recently requested budget month. BudgetView owns the selected
    /// month (@State); this mirrors the latest request so an older in-flight
    /// fetch can't publish over a newer one after its await.
    private var requestedBudgetMonth: String?

    func fetchBudgetMonth(_ month: String) async {
        requestedBudgetMonth = month
        do {
            let fetched = try await database?.fetchBudgetMonth(month: month)
            // If a newer month was requested while we were fetching (rapid
            // month flips), this result is stale — drop it.
            guard requestedBudgetMonth == month else { return }
            currentBudgetMonth = fetched
        } catch {
            guard requestedBudgetMonth == month else { return }
            self.error = error.localizedDescription
        }
    }

    // MARK: - Budget Amounts

    /// Parse the budget edit field ("25.50") into non-negative cents.
    static func budgetAmountCents(from string: String) throws -> Int {
        guard let dollars = Double(string),
              let cents = Transaction.cents(fromDollars: dollars),
              cents >= 0 else {
            throw BudgetStoreError.invalidAmount
        }
        return cents
    }

    /// Set the budgeted amount for a category, then refetch the month so the
    /// published Available/carryover figures recompute from the new value.
    func setBudgetAmount(month: String, categoryId: String, amountCents: Int) async throws {
        guard let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }
        try await syncClient.setBudgetAmount(month: month, categoryId: categoryId, amount: amountCents)
        await fetchBudgetMonth(month)
    }

    // MARK: - Currency Formatting

    /// Format an amount in cents to a currency string using the budget's currency
    /// - Parameter cents: Amount in cents (e.g., 1050 = $10.50)
    /// - Returns: Formatted currency string (e.g., "$10.50")
    func formatCurrency(_ cents: Int) -> String {
        let amount = Double(cents) / 100.0
        guard !currencyCode.isEmpty else {
            return amount.formatted(.number.precision(.fractionLength(2)))
        }
        return amount.formatted(.currency(code: currencyCode))
    }

    /// Like `formatCurrency`, but rounded to whole units (e.g., "$1,051").
    /// Used for compact chart annotations where cents add noise.
    func formatCurrencyWholeUnits(_ cents: Int) -> String {
        let amount = Double(cents) / 100.0
        guard !currencyCode.isEmpty else {
            return amount.formatted(.number.precision(.fractionLength(0)))
        }
        return amount.formatted(.currency(code: currencyCode).precision(.fractionLength(0)))
    }

    // MARK: - Helpers

    private static let yearMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    private func currentMonthString() -> String {
        Self.yearMonthFormatter.string(from: Date())
    }
}
