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
    case transferCategoriesMatch
    case transferAmountExceedsSource
    case invalidAmount
    case missingTransferDestination
    case payeeCreationFailed(String)
    case transferPartnerMissing
    case cannotConvertToTransfer
    case cannotConvertToSplit
    case splitNeedsTwoLines
    case splitAmountMismatch
    case invalidAccountName
    case accountCreationFailed(String)
    case invalidCategoryName
    case invalidCategoryGroupName
    case categoryCreationFailed(String)
    case categoryGroupCreationFailed(String)
    case ruleNeedsCondition
    case ruleNeedsAction
    case ruleInvalidCondition(field: String, op: String)
    case ruleInvalidAction
    case ruleEmptyValue(field: String)
    case ruleInvalidPattern(pattern: String)
    case ruleOwnedBySchedule
    case ruleNotSerializable

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
        case .transferCategoriesMatch:
            return "Money must move between two different categories"
        case .transferAmountExceedsSource:
            return "That source does not have enough available money"
        case .invalidAmount:
            return "Invalid amount"
        case .missingTransferDestination:
            return "Select a destination account"
        case .payeeCreationFailed(let message):
            return "Failed to create payee: \(message)"
        case .transferPartnerMissing:
            return "The other side of this transfer no longer exists"
        case .cannotConvertToTransfer:
            return "Can't turn a split transaction into a transfer"
        case .cannotConvertToSplit:
            return "Can't convert an existing transaction into a split"
        case .splitNeedsTwoLines:
            return "A split needs at least two lines"
        case .splitAmountMismatch:
            return "Split amounts must add up to the total"
        case .invalidAccountName:
            return "Enter an account name"
        case .accountCreationFailed(let message):
            return "Failed to create account: \(message)"
        case .invalidCategoryName:
            return "Enter a category name"
        case .invalidCategoryGroupName:
            return "Enter a category group name"
        case .categoryCreationFailed(let message):
            return "Failed to create category: \(message)"
        case .categoryGroupCreationFailed(let message):
            return "Failed to create category group: \(message)"
        case .ruleNeedsCondition:
            return "Add at least one condition."
        case .ruleNeedsAction:
            return "Add at least one action."
        case .ruleInvalidCondition(let field, let op):
            return "\"\(RuleSchema.label(op: op))\" can't be used with \(RuleSchema.label(field: field))."
        case .ruleInvalidAction:
            return "Choose a field for every action."
        case .ruleEmptyValue(let field):
            return "\(RuleSchema.label(field: field).capitalized) needs a value."
        case .ruleInvalidPattern(let pattern):
            return "\"\(pattern)\" isn't a valid regular expression."
        case .ruleOwnedBySchedule:
            return "This rule belongs to a schedule. Delete the schedule instead."
        case .ruleNotSerializable:
            return "This rule contains a value that can't be saved. Check the amounts."
        }
    }
}

/// A user-configured HTTP header applied to every request to the Actual
/// server. Used to authenticate through reverse proxies that guard the server
/// (e.g. Cloudflare Access service tokens: `CF-Access-Client-Id` /
/// `CF-Access-Client-Secret`). The `id` is UI-only and not persisted meaningfully.
struct CustomHeader: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = ""
    var value: String = ""
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

    @Published var fallbackServerURL: String = "" {
        didSet {
            UserDefaults.standard.set(fallbackServerURL, forKey: "fallbackServerURL")
        }
    }

    /// Extra HTTP headers the user wants stamped onto every server request
    /// (e.g. Cloudflare Access service-token headers). Persisted in the Keychain
    /// because values may be secrets. Assigning re-persists and pushes the live
    /// set to the network client.
    @Published var customHeaders: [CustomHeader] = [] {
        didSet {
            persistCustomHeaders()
            applyCustomHeadersToClient()
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
    @Published var schedules: [ScheduleSummary] = []
    @Published var upcomingScheduledTransactionLength: String?
    @Published var scheduleStatuses: [String: ScheduleStatus] = [:]
    @Published var currentBudgetMonth: BudgetMonth?
    /// Bumped every time the published data snapshot above is republished
    /// (budget load, local mutation, sync). Views that cache their own
    /// fetches (transaction pagers, report widgets) key reloads on this so
    /// changes made elsewhere in the app reach them without a pull-down.
    @Published private(set) var dataVersion = 0
    @Published var syncState: SyncState = .idle
    @Published var lastSyncTime: Date?

    /// True from the moment a budget is opened until its first sync attempt
    /// finishes. Everything on screen until then comes from the downloaded
    /// server snapshot (or the local copy the last launch left behind), which
    /// can trail the server by hours or days — the UI says so rather than
    /// presenting those figures as final (GH #126).
    @Published private(set) var isInitialSyncing = false

    /// Whether we may WRITE payee_locations CRDT messages (server >= 26.4.0,
    /// probed via `GET /info` after each budget load). Persisted per server
    /// URL so offline launches keep the last known answer.
    @Published private(set) var payeeLocationWritesEnabled = false

    /// Currency code for formatting (e.g., "USD", "EUR", "GBP")
    /// Persisted to UserDefaults, defaults to "USD"
    @Published var currencyCode: String = "USD" {
        didSet {
            UserDefaults.standard.set(currencyCode, forKey: "currencyCode")
        }
    }

    /// User-initiated currency changes (the Settings picker) go through
    /// here, not a direct `currencyCode = ...` assignment: it also persists
    /// the choice into the budget's own `preferences` table via sync, so it
    /// survives a relaunch instead of being silently overwritten by whatever
    /// value the DB load path finds there (GH #59). Every DB load already
    /// assigns `currencyCode` directly (bypassing this method), which is
    /// exactly what keeps this from looping back on itself.
    func setCurrencyCode(_ code: String) async {
        currencyCode = code
        guard let syncClient else { return }
        do {
            try await syncClient.updateCurrencyCode(code)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Show just the narrow currency symbol ("$" instead of "NZ$"/"US$"),
    /// for users who find the disambiguation prefix noisy (GH #83).
    /// Persisted to UserDefaults, defaults to off (standard symbols).
    @Published var useNarrowCurrencySymbol: Bool = false {
        didSet {
            UserDefaults.standard.set(useNarrowCurrencySymbol, forKey: "useNarrowCurrencySymbol")
        }
    }

    /// User-selected appearance (system / light / dark). Persisted to UserDefaults.
    @Published var appearanceMode: AppearanceMode = .system {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: "appearanceMode")
        }
    }

    /// Tab the app opens on at launch. Persisted to UserDefaults, defaults to
    /// Accounts. Read at launch via StartTab.persisted, so changes apply on
    /// the next launch.
    @Published var startTab: StartTab = .accounts {
        didSet {
            UserDefaults.standard.set(startTab.rawValue, forKey: StartTab.defaultsKey)
        }
    }

    /// How the Budget tab lays out its summary and category rows
    /// (actios-96wa). Persisted to UserDefaults; defaults to the clean
    /// card look from the App Store screenshots.
    @Published var budgetDisplayStyle: BudgetDisplayStyle = .clean {
        didSet {
            UserDefaults.standard.set(budgetDisplayStyle.rawValue, forKey: "budgetDisplayStyle")
        }
    }

    /// How transaction lists are presented (flat list vs grouped by date).
    /// Persisted to UserDefaults, defaults to flat list.
    @Published var transactionDisplayMode: TransactionDisplayMode = .flat {
        didSet {
            UserDefaults.standard.set(transactionDisplayMode.rawValue, forKey: TransactionDisplayMode.defaultsKey)
        }
    }
    
    /// What tapping a row in the Uncategorized list opens.
    /// Persisted to UserDefaults, defaults to the category picker.
    @Published var uncategorizedTapAction: UncategorizedTapAction = .categoryPicker {
        didSet {
            UserDefaults.standard.set(uncategorizedTapAction.rawValue, forKey: UncategorizedTapAction.defaultsKey)
        }
    }

    /// Whether Budget rows show a spent-vs-available progress bar.
    /// Persisted to UserDefaults, defaults to on.
    @Published var showBudgetProgressBars: Bool = true {
        didSet {
            UserDefaults.standard.set(showBudgetProgressBars, forKey: "showBudgetProgressBars")
        }
    }

    /// Whether the detailed style's group headers total their columns.
    /// Persisted to UserDefaults, defaults to on. Groups with long names are
    /// the reason this is optional: the totals cost the name real width, and
    /// not every budget file makes the sums worth it.
    @Published var showGroupTotals: Bool = true {
        didSet {
            UserDefaults.standard.set(showGroupTotals, forKey: "showGroupTotals")
        }
    }

    /// Whether the Budget tab shows a badge with the overspent-category
    /// count (GH #68). Persisted to UserDefaults, defaults to on.
    @Published var showOverspentBadge: Bool = true {
        didSet {
            UserDefaults.standard.set(showOverspentBadge, forKey: "showOverspentBadge")
        }
    }

    /// Whether amount fields accept conventional decimal entry. Persisted to
    /// UserDefaults and defaults to the established calculator-style entry.
    @Published var conventionalAmountEntry: Bool = false {
        didSet {
            UserDefaults.standard.set(conventionalAmountEntry, forKey: "conventionalAmountEntry")
        }
    }

    /// Whether monetary values are obscured wherever the app displays them:
    /// account balances, the budget table, reports, and transaction lists.
    /// Screens where the user is actively working with an amount (entering a
    /// transaction, reconciling against the bank) intentionally stay visible.
    ///
    /// This is a device-level privacy preference, rather than budget data: a
    /// person may want to hide amounts before handing their phone to someone,
    /// regardless of which budget is currently open. It persists across
    /// relaunches and defaults to showing balances.
    @Published var hideBalances: Bool = false {
        didSet {
            UserDefaults.standard.set(hideBalances, forKey: "hideBalances")
        }
    }

    /// Whether Budget hides categories with no budget left this month.
    /// Persisted to UserDefaults, defaults to off.
    @Published var hideZeroBudgetCategories: Bool = false {
        didSet {
            UserDefaults.standard.set(hideZeroBudgetCategories, forKey: "hideZeroBudgetCategories")
        }
    }

    /// Whether transaction lists show only uncleared transactions, so long
    /// histories don't bury the items that still need attention (GH #133).
    /// Persisted to UserDefaults, defaults to off.
    @Published var hideClearedTransactions: Bool = false {
        didSet {
            UserDefaults.standard.set(hideClearedTransactions, forKey: "hideClearedTransactions")
        }
    }

    /// Whether the Accounts list drops its Closed Accounts section, for
    /// budgets that have accumulated closed accounts over the years
    /// (GH #277). Persisted to UserDefaults, defaults to off.
    @Published var hideClosedAccounts: Bool = false {
        didSet {
            UserDefaults.standard.set(hideClosedAccounts, forKey: "hideClosedAccounts")
        }
    }

    /// Categories the Budget list should show. With the hide toggle on, only
    /// exactly-zero available drops out: overspent (negative) categories stay
    /// visible so problems that need fixing are never masked.
    func visibleCategoryBudgets(_ categories: [CategoryBudget]) -> [CategoryBudget] {
        hideZeroBudgetCategories ? categories.filter { $0.available != 0 } : categories
    }

    /// Closed accounts the Accounts list should show — none when the hide
    /// toggle is on. A view filter only: the All Accounts total still counts
    /// closed accounts, so hiding them can't quietly change the net worth on
    /// screen.
    var visibleClosedAccounts: [Account] {
        hideClosedAccounts ? [] : accounts.filter(\.closed)
    }

    /// One consistent-width replacement keeps masked amounts visually stable
    /// while avoiding a numeric value in the UI. Bullets read as the familiar
    /// passcode-style "hidden" treatment while inheriting each label's font,
    /// size, and color.
    static let hiddenBalanceText = "\u{2022}\u{2022}\u{2022}\u{2022}"

    /// Formats a standard currency amount unless the privacy mask is enabled.
    func displayBalance(_ cents: Int) -> String {
        hideBalances ? Self.hiddenBalanceText : formatCurrency(cents)
    }

    /// Equivalent to `displayBalance(_:)` for reports that intentionally omit
    /// cents in their normal presentation.
    func displayBalanceWholeUnits(_ cents: Int) -> String {
        hideBalances ? Self.hiddenBalanceText : formatCurrencyWholeUnits(cents)
    }

    /// The clean row's "Spent" caption, from the signed net activity
    /// (negative = spending). Spending keeps the familiar positive amount,
    /// but a net inflow keeps a leading "+" so a category that only received
    /// deposits can't masquerade as spending (GH #102).
    func displaySpentCaption(_ spentCents: Int) -> String {
        guard !hideBalances else { return Self.hiddenBalanceText }
        return spentCents > 0
            ? "+\(formatCurrency(spentCents))"
            : formatCurrency(-spentCents)
    }

    /// Whether transaction saves record the payee's location (GH #24).
    /// Persisted to UserDefaults, defaults to on. Off silences every
    /// recording path, including Shortcuts automations.
    @Published var recordPayeeLocations: Bool = true {
        didSet {
            UserDefaults.standard.set(recordPayeeLocations, forKey: "recordPayeeLocations")
        }
    }

    /// Whether due scheduled transactions are posted automatically after a
    /// successful sync on launch/foreground. Opt-in (defaults off) because
    /// every post writes to the user's real Actual server.
    @Published var postScheduledTransactions: Bool = false {
        didSet {
            UserDefaults.standard.set(postScheduledTransactions, forKey: "postScheduledTransactions")
        }
    }

    /// Transient toast text ("Posted N scheduled transaction(s)"), cleared
    /// automatically a few seconds after being set. Nil = no toast.
    @Published var schedulePostNotice: String?

    /// Count the Budget tab badge displays: the current month's overspent
    /// categories, or 0 when the badge is turned off in Settings.
    var overspentBadgeCount: Int {
        showOverspentBadge ? (currentBudgetMonth?.overspentCount ?? 0) : 0
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

    /// Mappings from card last-4 / bank keywords (e.g. "1234", "HSBC") -> accountId.
    /// Persisted per budget in UserDefaults.
    var cardAccountMappings: [String: String] {
        get {
            guard let budgetId = currentBudgetId else { return [:] }
            return UserDefaults.standard.dictionary(forKey: "cardAccountMappings_\(budgetId)") as? [String: String] ?? [:]
        }
        set {
            guard let budgetId = currentBudgetId else { return }
            UserDefaults.standard.set(newValue, forKey: "cardAccountMappings_\(budgetId)")
            objectWillChange.send()
        }
    }

    /// Resolves an account ID from a hint string (e.g. card digits "1234", bank name "HSBC",
    /// or account name). Matching is deliberately conservative — a missed match falls back
    /// to the default account or an error the user can act on, while a wrong match logs
    /// money to the wrong account silently.
    func resolveAccountId(hint: String) async -> String? {
        let trimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let activeAccounts = await accountsForIntent().filter { !$0.closed }
        guard !activeAccounts.isEmpty else { return nil }
        let activeIds = Set(activeAccounts.map(\.id))

        // 1. Mapping keywords the hint contains. Longest key first so "1234" beats "12"
        //    and multi-match resolution is deterministic (Dictionary order isn't). Only
        //    hint-contains-key: the reverse direction would let a one-character hint
        //    match any keyword.
        let mappingsByLongestKey = cardAccountMappings
            .map { (key: $0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                    accountId: $0.value) }
            .filter { !$0.key.isEmpty }
            .sorted { $0.key.count != $1.key.count ? $0.key.count > $1.key.count : $0.key < $1.key }
        for mapping in mappingsByLongestKey
        where trimmed.contains(mapping.key) && activeIds.contains(mapping.accountId) {
            return mapping.accountId
        }

        // 2. Exact account name match.
        if let exact = activeAccounts.first(where: { $0.name.lowercased() == trimmed }) {
            return exact.id
        }

        // 3. Whole-word name match ("Checking Account" hint -> "Checking" account), but
        //    only when it's unambiguous: substring matching would send "HSBC cashback"
        //    to an account named "Cash".
        let hintWords = Set(trimmed.split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
        let wordMatches = activeAccounts.filter { account in
            let nameWords = Set(account.name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
            guard !nameWords.isEmpty else { return false }
            return nameWords.isSubset(of: hintWords) || hintWords.isSubset(of: nameWords)
        }
        return wordMatches.count == 1 ? wordMatches[0].id : nil
    }

    // MARK: - Private

    private var serverClient = ActualServerClient()
    private var fileManager = BudgetFileManager.shared
    private var database: BudgetDatabase? {
        didSet {
            // The cached poster holds the database strongly; drop it whenever
            // the database identity changes so `database = nil` before a
            // re-import (downloadBudget) actually closes the GRDB connection.
            guard database !== oldValue else { return }
            schedulePoster = nil
        }
    }

    /// Read-only accessor for collaborators (e.g. TransactionLogger) that need
    /// direct DB access for queries that don't fit the @Published cache. The
    /// underlying `database` remains private to enforce that writes go through
    /// store methods.
    var databaseForLogger: BudgetDatabase? { database }

    /// Shared provider — one position cache for the whole app.
    static let locationProvider = LocationProvider()

    /// Nearby payees for the add-transaction form. Every failure path
    /// (no database, query error) degrades to "no suggestions".
    func fetchNearbyPayees(latitude: Double, longitude: Double) async -> [NearbyPayee] {
        guard let database else { return [] }
        do {
            return try await database.fetchNearbyPayees(latitude: latitude, longitude: longitude)
        } catch {
            logger.error("fetchNearbyPayees failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Tombstone one recorded payee location (swipe-delete on a nearby
    /// suggestion, GH #24). Returns whether the delete stuck; failures are
    /// logged and reported as false so the row can stay visible.
    func deletePayeeLocation(_ location: PayeeLocation) async -> Bool {
        guard payeeLocationWritesEnabled, let syncClient else { return false }
        do {
            try await syncClient.deletePayeeLocation(location)
            return true
        } catch {
            logger.error("deletePayeeLocation failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Payees that have recorded locations, for the Payee Locations screen
    /// (GH #147). Degrades to "nothing recorded" on any failure.
    func fetchPayeesWithLocations() async -> [PayeeLocationSummary] {
        guard let database else { return [] }
        do {
            return try await database.fetchPayeesWithLocations()
        } catch {
            logger.error("fetchPayeesWithLocations failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// The recorded locations for one payee, newest first.
    func fetchPayeeLocations(payeeId: String) async -> [PayeeLocation] {
        guard let database else { return [] }
        do {
            return try await database.fetchPayeeLocations(payeeId: payeeId)
        } catch {
            logger.error("fetchPayeeLocations failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Tombstone several recorded payee locations ("Clear All Locations").
    /// Same server-version gate as `deletePayeeLocation`; returns whether the
    /// delete stuck so the rows can stay visible on failure.
    func deletePayeeLocations(_ locations: [PayeeLocation]) async -> Bool {
        guard payeeLocationWritesEnabled, let syncClient else { return false }
        do {
            try await syncClient.deletePayeeLocations(locations)
            return true
        } catch {
            logger.error("deletePayeeLocations failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

#if DEBUG
    /// Records two locations against a known demo payee so PayeeLocationsUITests
    /// can exercise the clear paths. A UI test can't record a real coordinate —
    /// Core Location isn't drivable from XCUITest — so the app stands one in,
    /// the same trick -stampBackgroundRefreshOnBackground uses.
    func seedDebugPayeeLocations(payeeName: String) async {
        // Read the payee from the database, not the @Published cache: the demo
        // load that populates the cache may still be settling.
        guard let database,
              let payees = try? await database.fetchPayees(),
              let payee = payees.first(where: {
                  !$0.tombstone && $0.name == payeeName
              }) else {
            logger.error("seedDebugPayeeLocations: payee \(payeeName, privacy: .public) not found")
            return
        }
        // Sydney Opera House and Melbourne — far enough apart to be distinct rows.
        let coordinates = [(-33.8568, 151.2153), (-37.8136, 144.9631)]
        for (index, coordinate) in coordinates.enumerated() {
            do {
                try database.insertPayeeLocation(PayeeLocation(
                    id: "debug-loc-\(index)",
                    payeeId: payee.id,
                    latitude: coordinate.0,
                    longitude: coordinate.1,
                    createdAt: 1_751_760_000_000 + Int64(index)
                ))
            } catch {
                logger.error("seedDebugPayeeLocations insert failed: \(error, privacy: .public)")
            }
        }
    }
#endif

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
            // A completed load that produced no database *failed* — e.g. a
            // transient SQLITE_BUSY when a cold headless launch raced the
            // entity query's temporary connection (actios-tq4w). Never cache
            // that failure for the process lifetime: fall through and retry,
            // so every automation run gets a fresh attempt.
            if database != nil { return }
        }
        // No in-flight load (e.g. a freshly spawned headless process where the
        // init() Task hasn't been retained), or the last load failed. Start a
        // fresh one and await it.
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

    func categoriesForIntent() async -> [Category] {
        if !categoryGroups.isEmpty {
            return categoryGroups.flatMap(\.categories)
        }
        do {
            let db: BudgetDatabase
            if let database {
                db = database
            } else if let budgetId = currentBudgetId, fileManager.budgetExists(budgetId) {
                db = try BudgetDatabase(path: fileManager.databasePath(for: budgetId))
            } else {
                return []
            }
            let groups = try await db.fetchCategoryGroups()
            return groups.flatMap(\.categories)
        } catch {
            logger.error("categoriesForIntent DB fallback failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func categoryBudgetForIntent(categoryId: String) async -> CategoryBudget? {
        let currentMonth = currentMonthString()
        if let currentBudgetMonth, currentBudgetMonth.month == currentMonth {
            if let found = currentBudgetMonth.categoryBudgets.first(where: { $0.categoryId == categoryId }) {
                return found
            }
        }
        do {
            let db: BudgetDatabase
            if let database {
                db = database
            } else if let budgetId = currentBudgetId, fileManager.budgetExists(budgetId) {
                db = try BudgetDatabase(path: fileManager.databasePath(for: budgetId))
            } else {
                return nil
            }
            let monthBudget = try await db.fetchBudgetMonth(month: currentMonth)
            return monthBudget.categoryBudgets.first(where: { $0.categoryId == categoryId })
        } catch {
            logger.error("categoryBudgetForIntent DB fallback failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func payeesForIntent() async -> [Payee] {
        if !payees.isEmpty { return payees }
        do {
            let db: BudgetDatabase
            if let database {
                db = database
            } else if let budgetId = currentBudgetId, fileManager.budgetExists(budgetId) {
                db = try BudgetDatabase(path: fileManager.databasePath(for: budgetId))
            } else {
                return []
            }
            return try await db.fetchPayees()
        } catch {
            logger.error("payeesForIntent DB fallback failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private var syncClient: SyncClient?
    private var syncStateCancellable: AnyCancellable?
    
    // MARK: - Backups

    @Published private(set) var backups: [Backup] = []

    /// True while the user is viewing a restored backup — the revert baseline
    /// (db.latest.sqlite) exists. Taking a new backup consumes it, so the UI
    /// confirms first (backupOnBackground skips entirely for the same reason).
    var isViewingBackup: Bool { backups.contains(where: \.isLatest) }

    /// True when metadata carries a cloudFileId but no groupId (a backup was restored over a synced budget).
    /// Sync can't run again until the user re-downloads the server copy.
    @Published private(set) var syncDetachedByRestore = false

    private lazy var backupService = BackupService(fileManager: fileManager)

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
        subscribeToSyncState()
    }

    /// Test-only: install an already-completed load task that produced no
    /// database, simulating an init()-time load that failed (actios-tq4w).
    func simulateFailedInitialLoadForTesting() {
        loadTask = Task {}
    }

    /// Test-only: swap in a server client wired to a stub transport so the
    /// login and probe paths can be exercised without a reachable server.
    func setServerClientForTesting(_ client: ActualServerClient) {
        serverClient = client
    }

    /// Test-only: swap in a file manager rooted at a temp directory so
    /// logout()'s full wipe can be exercised without touching the shared
    /// Budgets directory (parallel suites create real budgets there).
    func setFileManagerForTesting(_ manager: BudgetFileManager) {
        fileManager = manager
        backupService = BackupService(fileManager: manager)
    }

    /// Test-only: whether loadLocalBudget wired a sync client (it must not
    /// for a budget detached by a backup restore).
    var isSyncConfiguredForTesting: Bool { syncClient != nil }
    #endif

    private init() {
        // Restore saved state. Preferences restore through the Published
        // backing storage (`_x = Published(initialValue:)`) rather than the
        // properties themselves: didSet DOES fire for wrapper-backed
        // properties even inside init, which would write every restored
        // value straight back to UserDefaults — permanently persisting
        // launch-argument (NSArgumentDomain) overrides like
        // `-startTab budget` from test runs (actios-96wa).
        _serverURL = Published(
            initialValue: UserDefaults.standard.string(forKey: "serverURL") ?? "")
        _fallbackServerURL = Published(
            initialValue: UserDefaults.standard.string(forKey: "fallbackServerURL") ?? "")
        // customHeaders intentionally assigns through the property: its
        // didSet also pushes the headers onto the live network client.
        customHeaders = Self.loadPersistedCustomHeaders()
        _currentBudgetId = Published(
            initialValue: UserDefaults.standard.string(forKey: "currentBudgetId"))
        _currencyCode = Published(
            initialValue: UserDefaults.standard.string(forKey: "currencyCode") ?? "USD")
        _useNarrowCurrencySymbol = Published(initialValue: UserDefaults.standard
            .object(forKey: "useNarrowCurrencySymbol") as? Bool ?? false)
        if let raw = UserDefaults.standard.string(forKey: "appearanceMode"),
           let mode = AppearanceMode(rawValue: raw) {
            _appearanceMode = Published(initialValue: mode)
        }
        _startTab = Published(initialValue: StartTab.persisted)
        if let raw = UserDefaults.standard.string(forKey: "budgetDisplayStyle"),
           let style = BudgetDisplayStyle(rawValue: raw) {
            _budgetDisplayStyle = Published(initialValue: style)
        }
        _transactionDisplayMode = Published(initialValue: TransactionDisplayMode.persisted)
        _uncategorizedTapAction = Published(initialValue: UncategorizedTapAction.persisted)
        _showBudgetProgressBars = Published(initialValue: UserDefaults.standard
            .object(forKey: "showBudgetProgressBars") as? Bool ?? true)
        _showGroupTotals = Published(initialValue: UserDefaults.standard
            .object(forKey: "showGroupTotals") as? Bool ?? true)
        _showOverspentBadge = Published(initialValue: UserDefaults.standard
            .object(forKey: "showOverspentBadge") as? Bool ?? true)
        _conventionalAmountEntry = Published(initialValue: UserDefaults.standard
            .object(forKey: "conventionalAmountEntry") as? Bool ?? false)
        _hideBalances = Published(initialValue: UserDefaults.standard
            .object(forKey: "hideBalances") as? Bool ?? false)
        _recordPayeeLocations = Published(initialValue: UserDefaults.standard
            .object(forKey: "recordPayeeLocations") as? Bool ?? true)
        // bool(forKey:) defaults to false — the correct opt-in default.
        _hideZeroBudgetCategories = Published(initialValue: UserDefaults.standard
            .bool(forKey: "hideZeroBudgetCategories"))
        _hideClearedTransactions = Published(initialValue: UserDefaults.standard
            .bool(forKey: "hideClearedTransactions"))
        _hideClosedAccounts = Published(initialValue: UserDefaults.standard
            .bool(forKey: "hideClosedAccounts"))
        _postScheduledTransactions = Published(initialValue: UserDefaults.standard
            .bool(forKey: "postScheduledTransactions"))

        let token = loadAndMigrateAuthToken()

        // Load local budget if available. The saved session is configured in
        // the same task, before the load, so the initial sync below is
        // authenticated.
        if let budgetId = currentBudgetId, fileManager.budgetExists(budgetId) {
            // Set before the task so the very first render already knows the
            // numbers it is about to draw are provisional (GH #126).
            isInitialSyncing = true
            loadTask = Task {
                if let token { await configureSavedSession(token: token) }
                await loadLocalBudget(budgetId)
                // On a cold launch the scene becomes .active before
                // loadLocalBudget has wired syncClient, so the scenePhase
                // foreground sync no-ops. Sync here once the client exists.
                await syncOnForeground()
                isInitialSyncing = false
            }
        } else if let token {
            Task { await configureSavedSession(token: token) }
        }
    }

    /// Configure server URL and token for sync to work on launch and app resume
    private func configureSavedSession(token: String) async {
        // Normalize here too: the field persists raw text per keystroke, and
        // only connect() normalizes — a value saved between connect and login
        // would otherwise fail validation on every subsequent launch.
        try? await serverClient.configure(
            serverURL: serverURL,
            fallbackServerURL: Self.normalizedServerURL(fallbackServerURL)
        )
        await serverClient.setToken(token)
        isConnected = true
    }

    private init(forPreview: Void) {
        // Empty preview store — no UserDefaults reads, no auto-load.
    }

    // MARK: - Custom Headers

    private static let customHeadersKey = "customHeaders"

    /// Load persisted headers from the Keychain. Best-effort: returns empty on
    /// any decode failure so a corrupt entry never blocks startup.
    private static func loadPersistedCustomHeaders() -> [CustomHeader] {
        guard let json = Keychain.get(for: customHeadersKey),
              let data = json.data(using: .utf8),
              let headers = try? JSONDecoder().decode([CustomHeader].self, from: data) else {
            return []
        }
        return headers
    }

    private func persistCustomHeaders() {
        // Drop rows the user left completely blank so they don't accumulate.
        let meaningful = customHeaders.filter {
            !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !meaningful.isEmpty else {
            try? Keychain.remove(for: Self.customHeadersKey)
            return
        }
        if let data = try? JSONEncoder().encode(meaningful),
           let json = String(data: data, encoding: .utf8) {
            try? Keychain.set(json, for: Self.customHeadersKey)
        }
    }

    /// Push the current header set to the network client. Only rows with a
    /// non-empty name are sent; names/values are trimmed of surrounding space.
    private func applyCustomHeadersToClient() {
        let headers: [(name: String, value: String)] = customHeaders
            .map { (name: $0.name.trimmingCharacters(in: .whitespaces),
                    value: $0.value.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.name.isEmpty }
        Task { await serverClient.setCustomHeaders(headers) }
    }

    // MARK: - Server Connection

    func connect() async {
        let normalized = Self.normalizedServerURL(serverURL)
        let normalizedFallback = Self.normalizedServerURL(fallbackServerURL)
        guard !normalized.isEmpty else {
            error = "Please enter a server URL"
            return
        }
        if normalized != serverURL {
            serverURL = normalized
        }
        if normalizedFallback != fallbackServerURL {
            fallbackServerURL = normalizedFallback
        }

        isLoading = true
        error = nil

        do {
            try await serverClient.configure(
                serverURL: normalized,
                fallbackServerURL: normalizedFallback
            )
            // Ensure the client carries the user's headers before any probe/login,
            // so servers behind an auth proxy are reachable from the first request.
            applyCustomHeadersToClient()
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

    /// The login methods a server is assumed to offer when the probe can't tell
    /// us — password auth is the safe assumption and keeps the flow usable.
    private static let passwordOnlyLoginMethods = [
        LoginMethod(method: "password", displayName: "Password", active: 1)
    ]

    /// Probe the configured server for its available login methods so the UI can
    /// offer password and/or OpenID sign-in. Best-effort: on failure we fall back
    /// to password-only so the existing flow keeps working.
    func checkLoginMethods() async {
        do {
            availableLoginMethods = try await serverClient.fetchLoginMethods()
        } catch ActualServerError.authProxyBlocked {
            // Surface the actionable hint proactively rather than waiting for the
            // login attempt to fail with the same cryptic-looking response.
            error = ActualServerError.authProxyBlocked.localizedDescription
            availableLoginMethods = Self.passwordOnlyLoginMethods
        } catch let probeError as ActualServerError where probeError.isConnectionFailure {
            // The server isn't reachable, so falling back to password login
            // would fail identically. Say why now — otherwise tapping Connect
            // with an empty password looks like it did nothing at all.
            error = probeError.localizedDescription
            availableLoginMethods = Self.passwordOnlyLoginMethods
        } catch {
            // Reachable, but the probe was unusable: older servers without the
            // endpoint, or a proxy stripping the route. Stay quiet and let the
            // login attempt report anything that's actually wrong.
            logger.error("Failed to fetch login methods: \(error.localizedDescription, privacy: .public)")
            availableLoginMethods = Self.passwordOnlyLoginMethods
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

    /// Clear the server session and, by default, wipe all local budget data.
    /// - Parameter clearLocalData: pass `false` to keep budget files on disk
    ///   (the demo entry point clears the session without destroying data;
    ///   only an explicit Disconnect wipes it).
    func logout(clearLocalData: Bool = true) {
        Task {
            await serverClient.setToken(nil)
        }
        try? Keychain.remove(for: "authToken")
        // Defensively remove any legacy UserDefaults copy
        UserDefaults.standard.removeObject(forKey: "authToken")

        // Close the open database and sync client BEFORE touching files.
        // A deleted-but-open database stays readable through its fd (the
        // "vnode unlinked" hazard downloadBudget also guards against), and a
        // live sync client would let the next foreground refresh republish
        // the wiped budget's data from that orphaned connection.
        syncStateCancellable?.cancel()
        syncStateCancellable = nil
        syncClient = nil
        database = nil

        if clearLocalData {
            // Wipe every locally-synced budget's database and metadata from
            // disk — disconnecting should leave nothing behind, not just the
            // auth token (GH: disconnect should clear local data). Encrypted
            // budgets' Keychain keys go too: they must not outlive the files
            // they unlock.
            for local in fileManager.listLocalBudgets() {
                if let fileId = local.cloudFileId {
                    try? EncryptionKeyManager.remove(fileId: fileId)
                }
                try? fileManager.deleteBudget(local.id)
            }
        }

        isConnected = false
        remoteBudgets = []
        // Re-probe on the next connection in case the server URL changes.
        availableLoginMethods = []
        ownerExists = true
        
        backups = []
        syncDetachedByRestore = false

        // Clear everything currently loaded in memory too, so nothing from
        // the old budget lingers in the UI post-disconnect. The dataVersion
        // bump makes views that cache their own fetches drop them.
        currentBudgetId = nil
        currentBudgetMonth = nil
        accounts = []
        transactions = []
        uncategorizedCount = 0
        categoryGroups = []
        payees = []
        lastSyncTime = nil
        syncState = .idle
        // No budget left to catch up — an in-flight initial sync's banner must
        // not outlive the budget it described.
        isInitialSyncing = false
        dataVersion += 1
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

        // Whether the budget actually got opened, so the initial sync below
        // runs only when there is something to catch up.
        var opened = false

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
            isInitialSyncing = true
            opened = true
            // The initial sync below can pull weeks of history, and this file's
            // messages_crdt rowids come from whichever client uploaded it, so a
            // watermark left by a previous copy of the same budget points at
            // unrelated messages — high enough to pass the detector's guard, low
            // enough to announce all that history as new transactions.
            NewTransactionDetector.forgetWatermark(budgetId: metadata.id)
            await loadLocalBudget(metadata.id)
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
        downloadingBudgetId = nil

        // Outside the download spinner: the budget is on screen from here, it
        // just isn't caught up yet.
        if opened { await runInitialSync() }
    }

    /// The first sync after a budget is opened. A downloaded budget is a server
    /// snapshot that can trail the server's message log by hours or days, so
    /// catch it up immediately instead of leaving those figures on screen until
    /// the next foreground or pull-to-refresh — which is how "outdated numbers"
    /// survived a fresh setup (GH #126).
    private func runInitialSync() async {
        defer { isInitialSyncing = false }
        guard syncClient != nil else { return }
        await sync()
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
            let fetchedUpcomingLength = try await openedDb.fetchUpcomingScheduledTransactionLength()
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
            
            upcomingScheduledTransactionLength = fetchedUpcomingLength
            
            accounts = fetchedAccounts
            transactions = fetchedTransactions
            uncategorizedCount = fetchedUncategorizedCount
            categoryGroups = fetchedGroups
            payees = fetchedPayees
            currentBudgetMonth = fetchedBudgetMonth
            dataVersion += 1

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
                syncDetachedByRestore = (metadata.cloudFileId != nil && groupId.isEmpty)
            } else {
                syncDetachedByRestore = false
                logger.notice("Could not load metadata for budget \(budgetId, privacy: .private)")
            }

            if syncDetachedByRestore {
                // A restored backup: the server still has the old sync group,
                // so any sync with our nulled groupId earns a 400
                // file-has-reset and an endless retry loop. Leave sync
                // unconfigured until a re-download writes a fresh groupId.
                syncStateCancellable?.cancel()
                syncStateCancellable = nil
                syncClient = nil
                syncState = .idle
                logger.notice("Budget detached by restore - sync not configured")
            } else {
                logger.info("Configuring sync with fileId: \(fileId, privacy: .private), groupId: \(groupId, privacy: .private)")
                let nodeId = UserDefaults.standard.string(forKey: "nodeId") ?? {
                    let id = HybridLogicalClock.generateNodeId()
                    UserDefaults.standard.set(id, forKey: "nodeId")
                    return id
                }()

                syncClient = SyncClient(serverClient: serverClient, nodeId: nodeId)

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

                subscribeToSyncState()
            }

            refreshPayeeLocationSupport()

        } catch {
            // If a concurrent load replaced our database mid-fetch, this
            // failure belongs to a stale load — don't clobber the winner's
            // error or clear its spinner.
            guard db == nil || database === db else { return }
            self.error = "Failed to load budget: \(error.localizedDescription)"
        }

        isLoading = false
    }

    /// Seed `payeeLocationWritesEnabled` from the last cached answer for the
    /// configured server, then probe `GET /info` in the background. A failed
    /// probe (unreachable, 404, parse error) keeps the cached answer; a
    /// successful one overwrites it. Never blocks or fails budget load.
    private func refreshPayeeLocationSupport() {
        let capturedURL = serverURL
        let key = "payeeLocationWritesEnabled_\(capturedURL)"
        payeeLocationWritesEnabled = UserDefaults.standard.bool(forKey: key)
        Task { [weak self] in
            guard let self else { return }
            guard let version = await self.serverClient.fetchServerVersion() else {
                return  // capabilities unknown — keep the cached answer
            }
            // The user may have switched servers while the probe was in
            // flight; a stale answer must not flip the flag for — or be
            // persisted under — a server other than the one probed.
            guard self.serverURL == capturedURL else { return }
            let supported = ServerVersion.supportsPayeeLocations(version)
            self.payeeLocationWritesEnabled = supported
            UserDefaults.standard.set(supported, forKey: key)
        }
    }

    func refreshData() async {
        guard let budgetId = currentBudgetId else { return }
        await loadLocalBudget(budgetId)
    }

    /// Populate a local "demo" budget with curated data, for screenshots and for
    /// letting users (and App Review) explore the app without configuring a server.
    /// Logs out any active server session so sync cannot fire against a real server.
    func loadDemoData(tracking: Bool = false) async {
        // Log out any active session so sync doesn't try to fire against a
        // real server — but keep local budget files: trying the demo must
        // never destroy a user's synced data.
        logout(clearLocalData: false)
        do {
            try DemoDataSeeder.seed(tracking: tracking)
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
            // Re-read here as well as on load: a sync can bring in a changed
            // upcoming window, and the status badges below are computed from it.
            let fetchedUpcomingLength = try await database.fetchUpcomingScheduledTransactionLength()

            // If the budget was switched while we were fetching, this
            // snapshot belongs to the old database — drop it.
            guard self.database === database else { return }

            accounts = fetchedAccounts
            transactions = fetchedTransactions
            uncategorizedCount = fetchedUncategorizedCount
            categoryGroups = fetchedGroups
            payees = fetchedPayees
            currentBudgetMonth = fetchedBudgetMonth
            upcomingScheduledTransactionLength = fetchedUpcomingLength
            dataVersion += 1

            await loadSchedules()
        } catch is CancellationError {
            // The caller's task was cancelled (e.g. a .refreshable task the
            // system tore down). Nothing failed — never alarm the user.
        } catch {
            // If the budget was switched mid-fetch, the failure belongs to
            // the old database — don't surface it over the new budget.
            guard self.database === database else { return }
            self.error = "Failed to refresh data: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Backup Actions

    func refreshBackups() async {
        guard let budgetId = currentBudgetId else {
            backups = []
            return
        }
        backups = await backupService.availableBackups(budgetId: budgetId)
    }

    func makeBackupNow() async {
        guard let budgetId = currentBudgetId else { return }
        do {
            try await backupService.makeBackup(budgetId: budgetId, database: database)
            await refreshBackups()
        } catch {
            self.error = error.localizedDescription
        }
    }
    
    /// Automatic backup on app-background. Skipped while viewing a backup.
    /// Backgrounding happens seconds after a restore (the user checks another app),
    /// and makeBackup's first step would destroy the revert baseline.
    func backupOnBackground() {
        guard let budgetId = currentBudgetId, let database else { return }
        let viewingBackup = FileManager.default.fileExists(
            atPath: fileManager.latestDatabasePath(for: budgetId).path
        )
        guard !viewingBackup else { return }
        let service = backupService
        Task { [weak self] in
            try? await service.makeBackup(budgetId: budgetId, database: database)
            await self?.refreshBackups()
        }
    }

    func restoreBackup(_ backupId: String) async {
        guard let budgetId = currentBudgetId else { return }
        isLoading = true
        error = nil

        // Drop the sync client and database references before loadBackup swaps
        // files. Any sync still running inside the old actor keeps the old
        // database open: its baseline snapshot goes through that queue's write
        // serialization (VACUUM INTO, never a raw file copy racing a write),
        // and post-swap writes land on the now-unlinked old inode (harmlessly
        // discarded). We deliberately do NOT flushPendingSync() here: that
        // awaits the network push and would hang this local restore for the
        // URLSession timeout when the server is unreachable.
        let openDatabase = database
        syncStateCancellable?.cancel()
        syncStateCancellable = nil
        syncClient = nil
        database = nil

        do {
            try await backupService.loadBackup(
                budgetId: budgetId, backupId: backupId, database: openDatabase
            )
        } catch {
            self.error = error.localizedDescription
        }

        // Reopen even after a failure: the live files are still (or again) a
        // valid budget, and the UI needs a database either way.
        await loadLocalBudget(budgetId)
        await refreshBackups()
        isLoading = false
    }
    
    /// On-disk location of a stored backup archive, so the user can export it via the share sheet (Save to Files, AirDrop, etc.) and import it into
    /// Actual on the web or desktop . The archive is already in Actual's import format (db.sqlite + metadata.json, CRDT state stripped).
    func backupFileURL(_ backupId: String) -> URL? {
        guard let budgetId = currentBudgetId else { return nil }
        return fileManager.backupPath(for: budgetId, name: backupId)
    }

    func revertToLatest() async {
        await restoreBackup(Backup.latest.id)
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

    // MARK: - Accounts

    /// Create a new local (manually-added) account, matching the PWA's own
    /// "Create local account" flow (loot-core `createAccount`): an accounts
    /// row, the account's transfer payee (the empty-named payee carrying
    /// `transfer_acct` that every transfer to or from this account resolves
    /// through), and — only for a nonzero balance, like the PWA — an
    /// opening-balance transaction from the shared "Starting Balance" payee
    /// (Actual has no separate stored-balance field — every account's balance
    /// is always the sum of its transactions, so this transaction IS the
    /// starting balance, not a display shortcut).
    @discardableResult
    func createAccount(name: String, offBudget: Bool, startingBalanceCents: Int) async throws -> Account {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw BudgetStoreError.invalidAccountName
        }
        guard let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }

        // New accounts sort after existing ones, same convention as new
        // transactions (Transaction.sortOrder) — a millisecond timestamp
        // keeps concurrent creates from colliding.
        let sortOrder = Int(Date().timeIntervalSince1970 * 1000)

        let account = Account(
            id: UUID().uuidString,
            name: trimmedName,
            type: .checking,
            offBudget: offBudget,
            closed: false,
            sortOrder: sortOrder,
            balance: startingBalanceCents
        )

        let transferPayee = Payee(
            id: UUID().uuidString,
            name: "",
            transferAccountId: account.id,
            tombstone: false
        )

        do {
            var startingBalanceTransaction: Transaction?
            if startingBalanceCents != 0 {
                let startingBalancePayee = try await findOrCreatePayee(name: "Starting Balance")

                // An on-budget opening balance is income the budget can
                // allocate, so it takes the income category the PWA picks
                // ("Starting Balances", else the first income category).
                // Off-budget money never enters the budget, so no category.
                let category = offBudget ? nil : startingBalanceCategory()

                startingBalanceTransaction = Transaction(
                    id: UUID().uuidString,
                    accountId: account.id,
                    date: Transaction.yyyymmdd(from: Date()),
                    amount: startingBalanceCents,
                    payeeId: startingBalancePayee.id,
                    payeeName: startingBalancePayee.name,
                    categoryId: category?.id,
                    categoryName: category?.name,
                    notes: nil,
                    cleared: true,
                    reconciled: false,
                    transferId: nil,
                    isParent: false,
                    parentId: nil,
                    tombstone: false,
                    sortOrder: nil,
                    importedPayee: nil,
                    startingBalanceFlag: true
                )
            }

            try await syncClient.createAccount(
                account,
                transferPayee: transferPayee,
                startingBalanceTransaction: startingBalanceTransaction
            )
        } catch let error as BudgetStoreError {
            throw error
        } catch {
            throw BudgetStoreError.accountCreationFailed(error.localizedDescription)
        }

        // Refresh local data (without recreating SyncClient, which would
        // cancel the scheduled sync) so the new account appears immediately.
        await refreshDataOnly()

        return account
    }

    /// The category an on-budget opening balance lands in, mirroring the
    /// PWA's `getStartingBalancePayee`: the income category named "Starting
    /// Balances" when the budget has one, else any income category, else nil
    /// (the transaction stays uncategorized, same as upstream).
    private func startingBalanceCategory() -> Category? {
        let incomeCategories = categoryGroups.flatMap(\.categories).filter(\.isIncome)
        return incomeCategories.first { $0.name.lowercased() == "starting balances" }
            ?? incomeCategories.first
    }
    
    /// Create a category group, mirroring the web UI's "Add group": it lands
    /// after every existing group and starts out empty. Duplicate names are
    /// refused the way upstream refuses them.
    @discardableResult
    func createCategoryGroup(name: String) async throws -> CategoryGroup {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw BudgetStoreError.invalidCategoryGroupName
        }
        guard let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }

        let group: CategoryGroup
        do {
            group = try await syncClient.createCategoryGroup(
                id: UUID().uuidString,
                name: trimmedName
            )
        } catch let error as BudgetDatabase.CategoryWriteError {
            // Already phrased for the person who typed the name.
            throw error
        } catch {
            throw BudgetStoreError.categoryGroupCreationFailed(error.localizedDescription)
        }

        await refreshDataOnly()

        return group
    }

    /// Create a category at the top of `groupId`, where the web UI puts it.
    /// The new category inherits the group's income and hidden flags, so an
    /// income group gets an income category.
    @discardableResult
    func createCategory(name: String, groupId: String) async throws -> Category {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw BudgetStoreError.invalidCategoryName
        }
        guard let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }

        let category: Category
        do {
            category = try await syncClient.createCategory(
                id: UUID().uuidString,
                name: trimmedName,
                categoryGroupId: groupId
            )
        } catch let error as BudgetDatabase.CategoryWriteError {
            throw error
        } catch {
            throw BudgetStoreError.categoryCreationFailed(error.localizedDescription)
        }

        await refreshDataOnly()

        return category
    }
    
    /// Money in and out across every account for one "yyyy-MM" month, for the
    /// accounts tab's summary group (GH #256). Nil when there's no budget open
    /// or the query failed, so the card keeps its last figures rather than
    /// flashing zeroes.
    func fetchAccountsMonthSummary(month: String) async -> BudgetDatabase.AccountsMonthSummary? {
        do {
            return try await database?.fetchAccountsMonthSummary(month: month)
        } catch is CancellationError {
            // The caller's task was cancelled (tab switch, a superseded
            // refresh). Nothing failed — never alarm the user.
            return nil
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    // MARK: - Transactions

    /// One page of transactions (newest first), optionally scoped to an
    /// account and/or filtered by free-text search. See
    /// BudgetDatabase.fetchTransactions for the exact semantics.
    func fetchTransactions(
        accountId: String? = nil,
        limit: Int = BudgetDatabase.transactionPageSize,
        offset: Int = 0,
        search: String? = nil,
        unclearedOnly: Bool = false
    ) async -> [Transaction] {
        do {
            return try await database?.fetchTransactions(
                accountId: accountId, limit: limit, offset: offset, search: search,
                unclearedOnly: unclearedOnly
            ) ?? []
        } catch is CancellationError {
            // The caller's task was cancelled (e.g. a superseded .task(id:)
            // search reload). Nothing failed — never alarm the user.
            return []
        } catch {
            self.error = error.localizedDescription
            return []
        }
    }

    /// Every transaction counting toward a category's spend, optionally
    /// narrowed to one "yyyy-MM" month (see
    /// BudgetDatabase.fetchCategoryTransactions for the exact filter).
    func fetchCategoryTransactions(categoryId: String, month: String? = nil) async -> [Transaction] {
        do {
            return try await database?.fetchCategoryTransactions(categoryId: categoryId, month: month) ?? []
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

    struct WalletImportResult: Equatable {
        var imported: Int
        var skippedDuplicates: Int
    }

    /// Import Wallet transactions picked via the FinanceKit transaction
    /// picker into an account (GH #55, Tier 1). Candidates whose
    /// `financial_id` already exists on the account are skipped, so
    /// re-importing an overlapping selection is safe. Each import runs the
    /// rules pass, same as manual entry.
    func importWalletTransactions(
        _ candidates: [WalletImportCandidate],
        accountId: String
    ) async throws -> WalletImportResult {
        guard let database, let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }
        var existing = try database.existingFinancialIds(accountId: accountId)
        
        // One rules/context fetch for the whole import, not one per row.
        let prepared = await syncClient.prepareRules()
        
        var imported = 0
        var skipped = 0
        for candidate in candidates {
            guard !existing.contains(candidate.id) else {
                skipped += 1
                continue
            }
            existing.insert(candidate.id)
            let payeeName = candidate.payeeName.isEmpty ? nil : candidate.payeeName
            let payeeId = try await resolvePayeeId(name: candidate.payeeName, editing: nil)
            let transaction = Transaction(
                id: UUID().uuidString,
                accountId: accountId,
                date: Transaction.yyyymmdd(from: candidate.date),
                amount: candidate.amountCents,
                payeeId: payeeId,
                payeeName: payeeName,
                categoryId: nil,
                categoryName: nil,
                notes: nil,
                cleared: candidate.cleared,
                reconciled: false,
                transferId: nil,
                isParent: false,
                parentId: nil,
                tombstone: false,
                sortOrder: nil,  // Set to Date.now() during insert
                importedPayee: payeeName,
                financialId: candidate.id
            )
            try await syncClient.createTransaction(transaction, prepared: prepared)
            imported += 1
        }
        await refreshDataOnly()
        return WalletImportResult(imported: imported, skippedDuplicates: skipped)
    }

    /// Dedup keys already on an account, for marking picker selections that
    /// were imported before. Read-only convenience for `WalletImportView`.
    func walletFinancialIds(accountId: String) -> Set<String> {
        (try? database?.existingFinancialIds(accountId: accountId)) ?? []
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

    /// Ids of the off-budget accounts, for the category rules shared by the
    /// transaction rows, the sync notification and transfer saves.
    var offBudgetAccountIds: Set<String> {
        Set(accounts.filter(\.offBudget).map(\.id))
    }

    /// Re-save an existing transfer: both legs take the new accounts, amount,
    /// date, notes and cleared state, with payees remapped to the (possibly
    /// re-targeted) accounts' transfer payees. `original` is whichever leg the
    /// user opened; its partner is fetched through `transferId`. A category
    /// survives only on an on-budget leg whose partner account is off-budget
    /// (Actual's rule — money leaving the budget still needs a category);
    /// every other configuration clears it.
    func updateTransfer(
        original: Transaction,
        fromAccountId: String,
        toAccountId: String,
        amountCents: Int,
        date: Int,
        notes: String?,
        cleared: Bool,
        categoryId: String?
    ) async throws {
        guard let syncClient, let database else {
            throw BudgetStoreError.syncNotConfigured
        }
        guard fromAccountId != toAccountId else {
            throw BudgetStoreError.transferAccountsMatch
        }
        guard amountCents > 0 else {
            throw BudgetStoreError.transferAmountNotPositive
        }
        guard let partnerId = original.transferId,
              let partner = try await database.fetchTransaction(id: partnerId) else {
            throw BudgetStoreError.transferPartnerMissing
        }
        let fromTransferPayee = transferPayee(forAccountId: fromAccountId)
        let toTransferPayee = transferPayee(forAccountId: toAccountId)
        guard let fromTransferPayee, let toTransferPayee else {
            throw BudgetStoreError.transferPayeeMissing
        }

        let offBudgetIds = offBudgetAccountIds
        // The edited leg takes the form's category, the partner keeps its own —
        // then both are cleared unless that leg is the categorizable side.
        func resolvedCategory(for leg: Transaction, accountId: String,
                              otherAccountId: String) -> String? {
            guard !offBudgetIds.contains(accountId),
                  offBudgetIds.contains(otherAccountId) else { return nil }
            return leg.id == original.id ? categoryId : leg.categoryId
        }

        // The opened row can be either leg; the negative one is the source.
        let (sourceLeg, targetLeg) = original.amount < 0
            ? (original, partner) : (partner, original)

        var source = sourceLeg
        source.accountId = fromAccountId
        source.amount = -amountCents
        source.payeeId = toTransferPayee.id
        source.categoryId = resolvedCategory(for: sourceLeg, accountId: fromAccountId,
                                             otherAccountId: toAccountId)
        source.date = date
        source.notes = notes
        source.cleared = cleared

        var target = targetLeg
        target.accountId = toAccountId
        target.amount = amountCents
        target.payeeId = fromTransferPayee.id
        target.categoryId = resolvedCategory(for: targetLeg, accountId: toAccountId,
                                             otherAccountId: fromAccountId)
        target.date = date
        target.notes = notes
        target.cleared = cleared

        let sourceChanges = Self.changedFields(original: sourceLeg, updated: source)
        if !sourceChanges.isEmpty {
            try await syncClient.updateTransaction(source, changedFields: sourceChanges)
        }
        let targetChanges = Self.changedFields(original: targetLeg, updated: target)
        if !targetChanges.isEmpty {
            try await syncClient.updateTransaction(target, changedFields: targetChanges)
        }
        await refreshDataOnly()
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

    /// Children share their parent's account, date and cleared state; keep
    /// them aligned after a parent edit (mirrors desktop split behavior —
    /// reports read the children, so a stale child date would misfile them).
    /// A payee change follows Actual's rule: children whose payee matched
    /// the parent's old payee follow it; per-line overrides keep theirs.
    private func cascadeSharedFieldsToChildren(
        of parent: Transaction,
        originalPayeeId: String?
    ) async throws {
        guard let database else { return }
        for child in try await database.fetchChildTransactions(parentId: parent.id) {
            var updated = child
            updated.accountId = parent.accountId
            updated.date = parent.date
            updated.cleared = parent.cleared
            if child.payeeId == originalPayeeId {
                updated.payeeId = parent.payeeId
            }
            if updated != child {
                try await updateTransaction(updated, original: child)
            }
        }
    }

    /// Split children of a parent, for the edit sheet's editable split lines.
    /// Failures collapse to an empty list — the sheet then behaves like the
    /// old read-only form (amount/category protected by the standard path).
    func fetchSplitChildren(parentId: String) async -> [Transaction] {
        guard let database else { return [] }
        return (try? await database.fetchChildTransactions(parentId: parentId)) ?? []
    }

    /// Soft-delete a transaction by setting its tombstone flag (CRDT-compatible).
    /// Failures surface through the published `error` string.
    func deleteTransaction(_ transaction: Transaction) async {
        do {
            guard let syncClient else {
                throw BudgetStoreError.syncNotConfigured
            }
            // Deleting a split deletes its children too — orphaned children
            // would be invisible in the list but still feed reports.
            if transaction.isParent, let database {
                for child in try await database.fetchChildTransactions(parentId: transaction.id) {
                    var deletedChild = child
                    deletedChild.tombstone = true
                    try await syncClient.updateTransaction(deletedChild, changedFields: ["tombstone"])
                }
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

    // MARK: - Reconciliation

    /// Toggle a transaction's cleared status from the list's status dot.
    /// A reconciled (locked) transaction unlocks instead — callers confirm
    /// that first — and keeps its cleared flag, matching Actual's desktop
    /// behavior. Failures surface through the published `error` string.
    func toggleCleared(_ transaction: Transaction) async {
        do {
            var updated = transaction
            if transaction.reconciled {
                updated.reconciled = false
            } else {
                updated.cleared.toggle()
            }
            try await updateTransaction(updated, original: transaction)
            if updated.isParent {
                try await cascadeSharedFieldsToChildren(
                    of: updated, originalPayeeId: transaction.payeeId
                )
            }
        } catch {
            self.error = "Failed to update cleared status: \(error.localizedDescription)"
        }
    }

    /// Cleared balance for one account — the figure reconciliation compares
    /// against the bank. Nil when no budget is open or the read fails.
    func clearedBalance(accountId: String) async -> Int? {
        guard let database else { return nil }
        do {
            return try await database.clearedBalance(accountId: accountId)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Cleared / uncleared / reconciled totals for the account-detail
    /// balance breakdown (GH #134). Nil when no budget is open or the read
    /// fails — the breakdown is silently omitted rather than surfacing an
    /// error for a purely informational row.
    func balanceBreakdown(accountId: String) async -> AccountBalanceBreakdown? {
        guard let database else { return nil }
        return try? await database.balanceBreakdown(accountId: accountId)
    }

    /// Finish reconciling: lock every cleared, not-yet-reconciled transaction
    /// in the account (reconciled = true), like upstream's lockTransactions.
    /// Returns the number of rows locked; 0 with `error` set on failure.
    @discardableResult
    func lockClearedTransactions(accountId: String) async -> Int {
        do {
            guard let database, let syncClient else {
                throw BudgetStoreError.syncNotConfigured
            }
            let transactions = try await database.fetchClearedUnreconciledTransactions(
                accountId: accountId
            )
            let locked = transactions.map { transaction in
                var locked = transaction
                locked.reconciled = true
                return locked
            }
            try await syncClient.updateTransactions(locked, changedFields: ["reconciled"])
            await refreshDataOnly()
            return locked.count
        } catch {
            self.error = "Failed to lock transactions: \(error.localizedDescription)"
            return 0
        }
    }

    /// Create the balance-adjustment transaction reconciliation offers when
    /// the cleared balance doesn't match the bank: a cleared, uncategorized
    /// entry for the difference, same shape as upstream's. Returns false
    /// with `error` set on failure.
    @discardableResult
    func createReconciliationAdjustment(accountId: String, amountCents: Int) async -> Bool {
        do {
            let adjustment = Transaction(
                id: UUID().uuidString,
                accountId: accountId,
                date: Transaction.yyyymmdd(from: Date()),
                amount: amountCents,
                payeeId: nil,
                payeeName: nil,
                categoryId: nil,
                categoryName: nil,
                notes: "Reconciliation balance adjustment",
                cleared: true,
                reconciled: false,
                transferId: nil,
                isParent: false,
                parentId: nil,
                tombstone: false,
                sortOrder: Date().timeIntervalSince1970 * 1000,
                importedPayee: nil
            )
            try await createTransaction(adjustment)
            return true
        } catch {
            self.error = "Failed to create adjustment: \(error.localizedDescription)"
            return false
        }
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
        var splits: [SplitLineForm] = []
        /// The edit form's "Remove Split": the user asked to collapse an
        /// existing split parent into a single transaction. Only meaningful
        /// when editing a parent; ignored otherwise (the view never sets it
        /// for the add flow or plain transactions).
        var collapseSplit: Bool = false
        /// Per-save opt-out for payee location recording (GH #24). Defaults
        /// on so Shortcuts and existing callers keep recording.
        var recordLocation: Bool = true
    }

    /// One line of a split entered in the form. `amount` is raw field text,
    /// unsigned like `TransactionForm.amount`; `isOpposite` runs the line
    /// against the transaction's direction — a refund inside a spend split
    /// (GH #216). An empty `payeeName` means the line inherits the
    /// transaction's payee (Actual's makeChild rule). `childId` links the
    /// line to an existing child row when editing a split parent; nil means
    /// the line is new.
    struct SplitLineForm: Identifiable, Equatable {
        let id: UUID
        var childId: String?
        var categoryId: String?
        var amount: String
        var isOpposite: Bool
        var notes: String
        var payeeName: String

        init(id: UUID = UUID(), childId: String? = nil, categoryId: String? = nil, amount: String = "", isOpposite: Bool = false, notes: String = "", payeeName: String = "") {
            self.id = id
            self.childId = childId
            self.categoryId = categoryId
            self.amount = amount
            self.isOpposite = isOpposite
            self.notes = notes
            self.payeeName = payeeName
        }
    }

    /// A validated split line: signed cents, ready to become a child row.
    /// `payeeName` nil means inherit the parent's payee.
    struct SplitPlanLine: Equatable {
        var categoryId: String?
        var amountCents: Int
        var notes: String?
        var payeeName: String? = nil
        var childId: String? = nil
    }

    /// The store-side action a form resolves to. Validation and routing are
    /// pure so they can be tested without a configured sync client.
    enum TransactionFormPlan: Equatable {
        case transfer(toAccountId: String, amountCents: Int)
        case standard(amountCents: Int)
        case split(amountCents: Int, lines: [SplitPlanLine])
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
            return try planStandardOrSplit(form, amountCents: -unsignedCents, sign: -1)
        case .income:
            return try planStandardOrSplit(form, amountCents: unsignedCents, sign: 1)
        }
    }

    /// Resolve an expense/income form to `.standard`, or `.split` when split
    /// lines are present: every line must parse to a positive amount and the
    /// lines must add up exactly to the total. An `isOpposite` line runs
    /// against the transaction's direction — a refund inside a spend
    /// (GH #216).
    private static func planStandardOrSplit(
        _ form: TransactionForm,
        amountCents: Int,
        sign: Int
    ) throws -> TransactionFormPlan {
        guard !form.splits.isEmpty else {
            return .standard(amountCents: amountCents)
        }
        guard form.splits.count >= 2 else {
            throw BudgetStoreError.splitNeedsTwoLines
        }
        let lines = try form.splits.map { line in
            guard let dollars = Double(line.amount),
                  let cents = Transaction.cents(fromDollars: dollars),
                  cents > 0 else {
                throw BudgetStoreError.invalidAmount
            }
            let payeeName = line.payeeName.trimmingCharacters(in: .whitespacesAndNewlines)
            return SplitPlanLine(
                categoryId: line.categoryId,
                amountCents: sign * (line.isOpposite ? -cents : cents),
                notes: line.notes.isEmpty ? nil : line.notes,
                payeeName: payeeName.isEmpty ? nil : payeeName,
                childId: line.childId
            )
        }
        guard lines.map(\.amountCents).reduce(0, +) == amountCents else {
            throw BudgetStoreError.splitAmountMismatch
        }
        return .split(amountCents: amountCents, lines: lines)
    }

    /// Save the add/edit form: transfers become a paired transfer, everything
    /// else resolves its payee and creates or (when `original` is non-nil)
    /// updates the transaction.
    func saveTransaction(_ form: TransactionForm, editing original: Transaction? = nil) async throws {
        let date = Transaction.yyyymmdd(from: form.date)
        let notes = form.notes.isEmpty ? nil : form.notes

        switch try Self.plan(for: form) {
        case .transfer(let toAccountId, let amountCents):
            if let original {
                // An existing transfer re-saves both of its legs; an ordinary
                // row is converted in place (GH #259) — pairing it into a
                // brand new transfer would orphan it (actios-7u6).
                guard original.transferId != nil else {
                    try await convertToTransfer(
                        original: original, form: form, otherAccountId: toAccountId,
                        amountCents: amountCents, date: date, notes: notes
                    )
                    return
                }
                try await updateTransfer(
                    original: original,
                    fromAccountId: form.accountId,
                    toAccountId: toAccountId,
                    amountCents: amountCents,
                    date: date,
                    notes: notes,
                    cleared: form.cleared,
                    categoryId: form.categoryId
                )
                return
            }
            try await createTransfer(
                fromAccountId: form.accountId,
                toAccountId: toAccountId,
                amountCents: amountCents,
                date: date,
                notes: notes,
                cleared: form.cleared
            )

        case .split(let amountCents, let lines):
            if let original {
                if original.isParent {
                    // Editing an existing split parent: reconcile its children
                    // against the form's lines.
                    try await updateSplit(
                        original: original, form: form,
                        amountCents: amountCents, lines: lines,
                        date: date, notes: notes
                    )
                    return
                }
                // Editing a plain transaction into a split: the original row
                // becomes the parent and the form's lines its children.
                // Transfers and split children stay refused — see
                // convertToSplit.
                try await convertToSplit(
                    original: original, form: form,
                    amountCents: amountCents, lines: lines,
                    date: date, notes: notes
                )
                return
            }
            let payeeId = try await resolvePayeeId(name: form.payeeName, editing: nil)
            let payeeName = form.payeeName.isEmpty ? nil : form.payeeName
            let parentId = UUID().uuidString
            // Explicit sort orders keep the children in entry order under the parent
            let parentSort = Date().timeIntervalSince1970 * 1000
            let parent = Transaction(
                id: parentId,
                accountId: form.accountId,
                date: date,
                amount: amountCents,
                payeeId: payeeId,
                payeeName: payeeName,
                categoryId: nil,  // split parents never carry a category
                categoryName: nil,
                notes: notes,
                cleared: form.cleared,
                reconciled: false,
                transferId: nil,
                isParent: true,
                parentId: nil,
                tombstone: false,
                sortOrder: parentSort,
                importedPayee: payeeName
            )
            var children: [Transaction] = []
            for (index, line) in lines.enumerated() {
                // Children inherit the parent's payee unless the line names
                // its own (Actual's makeChild semantics).
                let childPayeeId: String?
                let childPayeeName: String?
                if let lineName = line.payeeName, lineName != payeeName {
                    childPayeeId = try await resolvePayeeId(name: lineName, editing: nil)
                    childPayeeName = lineName
                } else {
                    childPayeeId = payeeId
                    childPayeeName = payeeName
                }
                children.append(Transaction(
                    id: UUID().uuidString,
                    accountId: form.accountId,
                    date: date,
                    amount: line.amountCents,
                    payeeId: childPayeeId,
                    payeeName: childPayeeName,
                    categoryId: line.categoryId,
                    categoryName: nil,
                    notes: line.notes,
                    cleared: form.cleared,
                    reconciled: false,
                    transferId: nil,
                    isParent: false,
                    parentId: parentId,
                    tombstone: false,
                    sortOrder: parentSort - Double(index + 1),
                    importedPayee: nil
                ))
            }
            guard let syncClient else {
                throw BudgetStoreError.syncNotConfigured
            }
            try await syncClient.createSplit(parent: parent, children: children)
            await refreshDataOnly()
            if form.recordLocation, let payeeId {
                recordPayeeLocationIfAppropriate(payeeId: payeeId)
            }

        case .standard(let amountCents):
            let payeeId = try await resolvePayeeId(name: form.payeeName, editing: original)
            let payeeName = form.payeeName.isEmpty ? nil : form.payeeName

            if let original {
                // "Remove Split": collapse the parent into a single
                // transaction — demote the parent and tombstone its
                // children in the same save.
                if original.isParent, form.collapseSplit {
                    try await collapseSplit(
                        original: original, form: form,
                        amountCents: amountCents, date: date, notes: notes
                    )
                    return
                }
                // Split parents: the amount is the children's sum and the
                // category lives on the children — never overwrite either
                // from the form.
                let updated = Transaction(
                    id: original.id,
                    accountId: form.accountId,
                    date: date,
                    amount: original.isParent ? original.amount : amountCents,
                    payeeId: payeeId,
                    payeeName: payeeName,
                    categoryId: original.isParent ? nil : form.categoryId,
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
                if original.isParent {
                    try await cascadeSharedFieldsToChildren(
                        of: updated, originalPayeeId: original.payeeId)
                }
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
                if form.recordLocation, let payeeId {
                    recordPayeeLocationIfAppropriate(payeeId: payeeId)
                }
            }
        }
    }

    /// Apply an edited split form to an existing split parent: the parent
    /// takes the form's total/payee/notes/date/cleared, lines with a
    /// `childId` update their child row, lines without one become new
    /// children, and children missing from the form are tombstoned.
    private func updateSplit(
        original: Transaction,
        form: TransactionForm,
        amountCents: Int,
        lines: [SplitPlanLine],
        date: Int,
        notes: String?
    ) async throws {
        guard let syncClient, let database else {
            throw BudgetStoreError.syncNotConfigured
        }

        let payeeId = try await resolvePayeeId(name: form.payeeName, editing: original)
        let payeeName = form.payeeName.isEmpty ? nil : form.payeeName
        let parent = Transaction(
            id: original.id,
            accountId: form.accountId,
            date: date,
            amount: amountCents,
            payeeId: payeeId,
            payeeName: payeeName,
            categoryId: nil,  // split parents never carry a category
            categoryName: nil,
            notes: notes,
            cleared: form.cleared,
            reconciled: original.reconciled,
            transferId: original.transferId,
            isParent: true,
            parentId: nil,
            tombstone: original.tombstone,
            sortOrder: original.sortOrder
        )
        let parentChanges = Self.changedFields(original: original, updated: parent)
        if !parentChanges.isEmpty {
            try await syncClient.updateTransaction(parent, changedFields: parentChanges)
        }

        let existingChildren = try await database.fetchChildTransactions(parentId: original.id)
        let childrenById = Dictionary(uniqueKeysWithValues: existingChildren.map { ($0.id, $0) })

        // Existing children keep their sort_order (updates never move rows);
        // new lines slot in below the current minimum, preserving the order
        // they were appended in the form.
        var nextNewSort = (existingChildren.compactMap(\.sortOrder).min()
            ?? original.sortOrder
            ?? Date().timeIntervalSince1970 * 1000)

        for line in lines {
            let existing = line.childId.flatMap { childrenById[$0] }
            // Children inherit the parent's payee unless the line names its
            // own (Actual's makeChild semantics). A line whose payee matched
            // the parent's loads back as "inherit", so a parent payee edit
            // follows through here just like cascadeSharedFieldsToChildren.
            let childPayeeId: String?
            let childPayeeName: String?
            if let lineName = line.payeeName, lineName != payeeName {
                childPayeeId = try await resolvePayeeId(name: lineName, editing: existing)
                childPayeeName = lineName
            } else {
                childPayeeId = payeeId
                childPayeeName = payeeName
            }

            if let existing {
                let updated = Transaction(
                    id: existing.id,
                    accountId: form.accountId,
                    date: date,
                    amount: line.amountCents,
                    payeeId: childPayeeId,
                    payeeName: childPayeeName,
                    categoryId: line.categoryId,
                    categoryName: nil,
                    notes: line.notes,
                    cleared: form.cleared,
                    reconciled: existing.reconciled,
                    transferId: existing.transferId,
                    isParent: false,
                    parentId: original.id,
                    tombstone: false,
                    sortOrder: existing.sortOrder
                )
                let changes = Self.changedFields(original: existing, updated: updated)
                if !changes.isEmpty {
                    try await syncClient.updateTransaction(updated, changedFields: changes)
                }
            } else {
                nextNewSort -= 1
                // Rules are skipped, matching createSplit — the user just
                // spelled out every field on this line explicitly.
                try await syncClient.createTransaction(Transaction(
                    id: UUID().uuidString,
                    accountId: form.accountId,
                    date: date,
                    amount: line.amountCents,
                    payeeId: childPayeeId,
                    payeeName: childPayeeName,
                    categoryId: line.categoryId,
                    categoryName: nil,
                    notes: line.notes,
                    cleared: form.cleared,
                    reconciled: false,
                    transferId: nil,
                    isParent: false,
                    parentId: original.id,
                    tombstone: false,
                    sortOrder: nextNewSort,
                    importedPayee: nil
                ), applyRules: false)
            }
        }

        // Lines removed from the form tombstone their child rows — orphaned
        // children would be invisible in the list but still feed reports.
        let keptIds = Set(lines.compactMap(\.childId))
        for child in existingChildren where !keptIds.contains(child.id) {
            var deleted = child
            deleted.tombstone = true
            try await syncClient.updateTransaction(deleted, changedFields: ["tombstone"])
        }

        await refreshDataOnly()
        if form.recordLocation, let payeeId {
            recordPayeeLocationIfAppropriate(payeeId: payeeId)
        }
    }

    /// Convert an ordinary transaction into one leg of a transfer (GH #259):
    /// the row keeps its id and history (reconciled, sort order, imported
    /// payee), its payee becomes the other account's transfer payee, and a
    /// new partner leg is created in that account for the opposite amount.
    /// Mirrors upstream `addTransfer` (packages/loot-core/src/server/
    /// transactions/transfer.ts), where converting is likewise "point the
    /// payee at another account" — the edited row itself is never replaced.
    ///
    /// The row keeps its direction too: an imported outflow stays an outflow,
    /// so the amount the bank reported can't flip sign under the user. Split
    /// parents and children are refused, matching upstream's `is_parent`
    /// bail-out (a parent's amount is its children's, and a child has no row
    /// of its own to pair).
    private func convertToTransfer(
        original: Transaction,
        form: TransactionForm,
        otherAccountId: String,
        amountCents: Int,
        date: Int,
        notes: String?
    ) async throws {
        guard let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }
        guard !original.isParent, original.parentId == nil else {
            throw BudgetStoreError.cannotConvertToTransfer
        }
        guard form.accountId != otherAccountId else {
            throw BudgetStoreError.transferAccountsMatch
        }
        guard amountCents > 0 else {
            throw BudgetStoreError.transferAmountNotPositive
        }
        guard let legTransferPayee = transferPayee(forAccountId: form.accountId),
              let otherTransferPayee = transferPayee(forAccountId: otherAccountId) else {
            throw BudgetStoreError.transferPayeeMissing
        }

        let signedAmount = original.amount < 0 ? -amountCents : amountCents
        // Actual's rule: a transfer leg takes a category only when it sits in
        // an on-budget account and the other side is off-budget. The new
        // partner leg has no category of its own to keep either way.
        let offBudgetIds = offBudgetAccountIds
        let legCategoryId = !offBudgetIds.contains(form.accountId)
            && offBudgetIds.contains(otherAccountId) ? form.categoryId : nil

        let partnerId = UUID().uuidString
        var leg = original
        leg.accountId = form.accountId
        leg.amount = signedAmount
        leg.payeeId = otherTransferPayee.id
        leg.categoryId = legCategoryId
        leg.date = date
        leg.notes = notes
        leg.cleared = form.cleared
        leg.transferId = partnerId

        let partner = Transaction(
            id: partnerId,
            accountId: otherAccountId,
            date: date,
            amount: -signedAmount,
            payeeId: legTransferPayee.id,
            payeeName: nil,
            categoryId: nil,
            categoryName: nil,
            notes: notes,
            // Upstream's addTransfer inserts the partner uncleared: it's a row
            // the bank never reported, whatever the imported side says.
            cleared: false,
            reconciled: false,
            transferId: original.id,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: nil,
            importedPayee: nil
        )

        // Both rows commit together: an edited row whose transferred_id
        // outlived a failed partner insert would be a half-transfer, already
        // on its way to the server.
        try await syncClient.convertToTransfer(
            leg: leg,
            changedFields: Self.changedFields(original: original, updated: leg),
            partner: partner
        )
        await refreshDataOnly()
    }

    /// Convert an ordinary (non-split) transaction into a split: the
    /// original row becomes the parent — no category of its own, amount set
    /// to the children's sum, history (reconciled, sort order, imported
    /// payee) preserved — and the form's lines become its children, slotting
    /// in below the parent like new lines in `updateSplit`. Transfers are
    /// refused because the paired row in the other account references this
    /// one through `transferId`, and splitting would orphan that link;
    /// split children are refused because there is no row of their own to
    /// promote to parent.
    private func convertToSplit(
        original: Transaction,
        form: TransactionForm,
        amountCents: Int,
        lines: [SplitPlanLine],
        date: Int,
        notes: String?
    ) async throws {
        guard let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }
        guard original.transferId == nil, original.parentId == nil else {
            throw BudgetStoreError.cannotConvertToSplit
        }

        let payeeId = try await resolvePayeeId(name: form.payeeName, editing: original)
        let payeeName = form.payeeName.isEmpty ? nil : form.payeeName

        let parent = Transaction(
            id: original.id,
            accountId: form.accountId,
            date: date,
            amount: amountCents,
            payeeId: payeeId,
            payeeName: payeeName,
            categoryId: nil,  // split parents never carry a category
            categoryName: nil,
            notes: notes,
            cleared: form.cleared,
            reconciled: original.reconciled,
            transferId: nil,
            isParent: true,
            parentId: nil,
            tombstone: original.tombstone,
            sortOrder: original.sortOrder,
            importedPayee: original.importedPayee
        )
        let parentChanges = Self.changedFields(original: original, updated: parent)
        if !parentChanges.isEmpty {
            try await syncClient.updateTransaction(parent, changedFields: parentChanges)
        }

        // Children inherit the parent's payee unless the line names its own
        // (Actual's makeChild semantics). Rules are skipped, matching
        // createSplit/updateSplit — every field came from the form.
        var nextSort = original.sortOrder ?? Date().timeIntervalSince1970 * 1000
        for line in lines {
            nextSort -= 1
            let childPayeeId: String?
            let childPayeeName: String?
            if let lineName = line.payeeName, lineName != payeeName {
                childPayeeId = try await resolvePayeeId(name: lineName, editing: nil)
                childPayeeName = lineName
            } else {
                childPayeeId = payeeId
                childPayeeName = payeeName
            }
            try await syncClient.createTransaction(Transaction(
                id: UUID().uuidString,
                accountId: form.accountId,
                date: date,
                amount: line.amountCents,
                payeeId: childPayeeId,
                payeeName: childPayeeName,
                categoryId: line.categoryId,
                categoryName: nil,
                notes: line.notes,
                cleared: form.cleared,
                reconciled: false,
                transferId: nil,
                isParent: false,
                parentId: original.id,
                tombstone: false,
                sortOrder: nextSort,
                importedPayee: nil
            ), applyRules: false)
        }

        await refreshDataOnly()
        if form.recordLocation, let payeeId {
            recordPayeeLocationIfAppropriate(payeeId: payeeId)
        }
    }

    /// Collapse a split parent back into a single transaction (the edit
    /// form's "Remove Split"): the parent row keeps its id and history
    /// (reconciled, sort order, imported payee), picks up the form's amount
    /// and category, and is demoted (isParent = false). Every live child is
    /// tombstoned in the same save — orphaned children would be invisible in
    /// the list but still feed reports, so leaving them would double-count
    /// the collapsed amount. Mirrors Actual's desktop "un-split".
    private func collapseSplit(
        original: Transaction,
        form: TransactionForm,
        amountCents: Int,
        date: Int,
        notes: String?
    ) async throws {
        guard let syncClient, let database else {
            throw BudgetStoreError.syncNotConfigured
        }
        guard original.isParent else { return }

        let payeeId = try await resolvePayeeId(name: form.payeeName, editing: original)
        let payeeName = form.payeeName.isEmpty ? nil : form.payeeName

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
            isParent: false,
            parentId: nil,
            tombstone: original.tombstone,
            sortOrder: original.sortOrder,
            importedPayee: original.importedPayee
        )
        let changes = Self.changedFields(original: original, updated: updated)
        if !changes.isEmpty {
            try await syncClient.updateTransaction(updated, changedFields: changes)
        }

        for child in try await database.fetchChildTransactions(parentId: original.id) {
            var deleted = child
            deleted.tombstone = true
            try await syncClient.updateTransaction(deleted, changedFields: ["tombstone"])
        }

        await refreshDataOnly()
        if form.recordLocation, let payeeId {
            recordPayeeLocationIfAppropriate(payeeId: payeeId)
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

    /// Record only when no existing location for the payee is within 500 m
    /// (upstream dedupe rule).
    static func shouldRecordLocation(at position: Coordinates, existing: [PayeeLocation]) -> Bool {
        !existing.contains { location in
            LocationUtils.calculateDistanceMeters(
                lat1: position.latitude, lon1: position.longitude,
                lat2: location.latitude, lon2: location.longitude
            ) <= LocationUtils.defaultMaxDistanceMeters
        }
    }

    /// Fire-and-forget: attach the current position to `payeeId`. All guards
    /// and failures collapse to "do nothing" — recording a location must
    /// never affect the save that triggered it.
    func recordPayeeLocationIfAppropriate(payeeId: String) {
        guard payeeLocationWritesEnabled, recordPayeeLocations else { return }
        Task { [weak self] in
            guard let self else { return }
            let provider = Self.locationProvider
            guard await provider.authorizationStatus() == .granted,
                  let position = try? await provider.currentPosition(),
                  LocationUtils.isValidCoordinate(
                      latitude: position.latitude, longitude: position.longitude),
                  let database = self.database,
                  let existing = try? await database.fetchPayeeLocations(payeeId: payeeId),
                  Self.shouldRecordLocation(at: position, existing: existing),
                  let syncClient = self.syncClient else {
                return
            }
            let location = PayeeLocation(
                id: UUID().uuidString,
                payeeId: payeeId,
                latitude: position.latitude,
                longitude: position.longitude,
                createdAt: Int64(Date().timeIntervalSince1970 * 1000)
            )
            do {
                try await syncClient.createPayeeLocation(location)
                logger.debug("Recorded payee location for \(payeeId, privacy: .private)")
            } catch {
                logger.error("Failed to record payee location: \(error.localizedDescription, privacy: .public)")
            }
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
        // Pull-to-refresh runs this inside SwiftUI's .refreshable task, which
        // the system cancels on further scroll interaction or when the
        // hosting scroll view goes away (tab switch). Run the pipeline in an
        // unstructured task so a UI-driven cancellation can't abort a sync
        // mid-flight or poison the refresh reads with CancellationError.
        let work = Task {
            logger.info("sync() called")
            if syncClient == nil {
                logger.notice("syncClient is nil, cannot sync!")
            }
            await syncClient?.syncNow()
            lastSyncTime = Date()
            logger.debug("sync() completed, refreshing data...")
            await refreshDataOnly()
            await notifyAboutSyncedTransactions()
        }
        await work.value
    }

    /// Discard local sync state and re-adopt the server's Merkle tree.
    /// Used to recover when the client is stuck in a divergent state.
    func resetSyncState() async {
        logger.notice("resetSyncState() called from BudgetStore")
        await syncClient?.resetSyncState()
        lastSyncTime = Date()
        await refreshDataOnly()
    }

    /// Wait for the background push a local write kicked off (see
    /// `SyncClient.scheduleAutomaticSync`). Only headless callers that can be
    /// suspended right after writing need this — interactive flows must never
    /// block on the network (issue #125).
    func flushPendingSync() async {
        await syncClient?.flushPendingSync()
    }

    /// Whether local writes are still waiting to reach the server. Meaningful
    /// straight after `flushPendingSync()`: true there means the push failed and
    /// the rows live only on this device until the next successful sync.
    func hasPendingLocalWrites() async -> Bool {
        await syncClient?.hasPendingLocalWrites() ?? false
    }

    /// Sync when app enters foreground - only if a budget is loaded
    /// Uses rate-limited automatic sync to avoid redundant syncs
    func syncOnForeground() async {
        // After a failover, probe whether the primary recovered while we were
        // backgrounded. Fire-and-forget: the sync below proceeds on whichever
        // address is currently active and never waits on the probe.
        Task { await serverClient.retryPrimaryIfRecovered() }
        guard let client = syncClient else {
            logger.debug("syncOnForeground() skipped - no budget loaded")
            return
        }
        logger.info("syncOnForeground() - app became active, syncing...")
        let success = await client.automaticSync()
        lastSyncTime = Date()
        // Post due schedules between the sync and the data refresh so any
        // posted transactions appear in the same refresh. Only after a
        // successful sync: posting against stale data risks double-posting
        // an occurrence another client already covered.
        if success { await postDueSchedulesIfNeeded() }
        await refreshDataOnly()
        await notifyAboutSyncedTransactions()
    }

    /// Headless sync for background refresh. On a cold background launch the
    /// scene never activates, so ensure the saved budget is loaded (same path
    /// App Intents use) before syncing. Returns false when no budget is
    /// configured; true means a loaded budget attempted a sync — the server
    /// may still have been unreachable (SyncClient logs and retries later).
    func syncInBackground() async -> Bool {
        await ensureBudgetReady()
        guard let client = syncClient else {
            logger.debug("syncInBackground() skipped - no budget configured")
            return false
        }
        await client.automaticSync()
        lastSyncTime = Date()
        await refreshDataOnly()
        return true
    }

    /// Single transaction by id (cache first, then database) for notification
    /// tap-through. Nil when it no longer exists.
    func transaction(withId id: String) async -> Transaction? {
        if let cached = transactions.first(where: { $0.id == id }) { return cached }
        guard let database else { return nil }
        return (try? await database.fetchTransaction(id: id)) ?? nil
    }

    /// Detect transactions that arrived via the sync just completed and post
    /// the summary notification for them. Shared by the foreground and
    /// background sync paths so behavior is uniform: a foreground sync posts
    /// the same notification a background refresh would (NotificationRouter's
    /// willPresent shows it as a banner in-app) instead of silently consuming
    /// it. Opt-in and permission are enforced inside NewTransactionNotifier.
    func notifyAboutSyncedTransactions() async {
        let fresh = await detectNewTransactionsForNotification()
        // The sync that just ran refreshed the accounts cache, so names are
        // current even on a cold background launch.
        let accountNames = accounts.reduce(into: [String: String]()) {
            $0[$1.id] = $1.name
        }
        await NewTransactionNotifier.notify(about: fresh, currencyCode: currencyCode,
                                            narrowSymbol: useNarrowCurrencySymbol,
                                            accountNames: accountNames,
                                            offBudgetAccountIds: offBudgetAccountIds)
    }

    /// Transactions that arrived via sync since the last check (advances the
    /// notification watermark). Errors are logged, not thrown — a failed
    /// detection must never take down the background refresh.
    func detectNewTransactionsForNotification() async -> [Transaction] {
        guard let database, let syncClient, let budgetId = currentBudgetId else { return [] }
        do {
            return try await NewTransactionDetector().detectNewTransactions(
                in: database, budgetId: budgetId, localNode: syncClient.nodeId)
        } catch {
            logger.error("New-transaction detection failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - Scheduled Transaction Posting

    /// One poster held per database, NOT one per call: `syncOnForeground()`
    /// can run twice concurrently (the cold-launch loadTask calls it while
    /// the scenePhase .active handler fires its own Task), and the poster's
    /// double-post reentrancy guard is per-instance. Cleared by `database`'s
    /// didSet whenever the database identity changes (budget switch, or the
    /// defensive close before re-import), so it can never pin a stale GRDB
    /// connection open.
    private var schedulePoster: SchedulePoster?
    private var scheduleNoticeDismissTask: Task<Void, Never>?

    /// The toast copy for a completed posting pass.
    static func schedulePostNoticeText(count: Int) -> String {
        "Posted \(count) scheduled transaction\(count == 1 ? "" : "s")"
    }

    /// Mirror sync state into the published property, and post due schedules
    /// whenever a sync completes successfully (.syncing → .idle; performSync
    /// is the only sender of that transition). loot-core runs its schedule
    /// service on every sync completion event, so posting must not depend on
    /// WHICH sync succeeded: before this hook existed the only trigger was
    /// inline in syncOnForeground(), and a foreground attempt that failed
    /// (network not up yet at wake) with the retry ladder succeeding seconds
    /// later — or a pull-to-refresh / background-push sync — never posted
    /// anything (GH #97).
    private func subscribeToSyncState() {
        syncStateCancellable = syncClient?.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let wasSyncing = syncState == .syncing
                syncState = state
                if wasSyncing, state == .idle {
                    Task { await self.postDueSchedulesAfterSync() }
                }
            }
    }

    /// Sink-triggered posting for syncs that finish outside
    /// syncOnForeground() — that path refreshes after posting itself; here
    /// nothing else would republish the register, so refresh when anything
    /// posted.
    private func postDueSchedulesAfterSync() async {
        if await postDueSchedulesIfNeeded() > 0 {
            await refreshDataOnly()
        }
    }

    @discardableResult
    private func postDueSchedulesIfNeeded() async -> Int {
        guard postScheduledTransactions,
              let client = syncClient,
              let database,
              let budgetId = currentBudgetId else { return 0 }
        // Lazy-create; no suspension between this check and the cache write,
        // so two MainActor-interleaved calls still share one instance.
        let poster: SchedulePoster
        if let cached = schedulePoster {
            poster = cached
        } else {
            poster = SchedulePoster(database: database, actions: client)
            schedulePoster = poster
        }
        let count = await poster.runIfNeeded(budgetId: budgetId)
        guard count > 0 else { return 0 }
        schedulePostNotice = Self.schedulePostNoticeText(count: count)
        scheduleNoticeDismissTask?.cancel()
        scheduleNoticeDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.schedulePostNotice = nil
        }
        return count
    }
    
    // MARK: - Scheduled Transactions
    
    /// Refresh the schedules cache and recompute every status. Statuses depend
    /// on today's date as well as on transactions, so they are derived here on
    /// every refresh rather than cached against a schedule row.
    func loadSchedules() async {
        guard let database else {
            schedules = []
            scheduleStatuses = [:]
            return
        }
        do {
            let loaded = try await database.fetchSchedules()
            let paid = try await database.fetchPaidScheduleIds(for: loaded)
            let today = DayDate.today()

            var statuses: [String: ScheduleStatus] = [:]
            for schedule in loaded {
                statuses[schedule.id] = ScheduleStatusCalculator.status(
                    nextDate: schedule.nextDate,
                    completed: schedule.completed,
                    hasTransaction: paid.contains(schedule.id),
                    upcomingLength: schedule.customUpcomingLength ?? upcomingScheduledTransactionLength,
                    today: today)
            }

            schedules = loaded.sorted(by: Self.scheduleOrder)
            scheduleStatuses = statuses
        } catch {
            logger.error("Failed to load schedules: \(error, privacy: .public)")
            schedules = []
            scheduleStatuses = [:]
        }
    }

    /// Explicit `sort_order` first (the web's manual ordering), then soonest
    /// next date, then name — so a budget that has never been reordered still
    /// reads sensibly.
    private static func scheduleOrder(_ a: ScheduleSummary, _ b: ScheduleSummary) -> Bool {
        switch (a.sortOrder, b.sortOrder) {
        case let (x?, y?) where x != y: return x < y
        case (nil, _?): return false
        case (_?, nil): return true
        default: break
        }
        switch (a.nextDate, b.nextDate) {
        case let (x?, y?) where x != y: return x < y
        case (nil, _?): return false
        case (_?, nil): return true
        default: break
        }
        return (a.name ?? "").localizedCaseInsensitiveCompare(b.name ?? "") == .orderedAscending
    }
    
    @discardableResult
    func createSchedule(fields: ScheduleFormFields) async throws -> String {
        try await createSchedules([fields])[0]
    }

    /// Create one or more schedules, refreshing once at the end. "Find
    /// schedules" creates a whole selection at a time, and a full refresh per
    /// schedule re-reads every account, transaction and payee for nothing.
    @discardableResult
    func createSchedules(_ fields: [ScheduleFormFields]) async throws -> [String] {
        guard let syncClient else { throw BudgetStoreError.syncNotConfigured }

        var ids: [String] = []
        do {
            for field in fields {
                ids.append(try await syncClient.createSchedule(fields: field))
            }
        } catch {
            // Whatever got through is already on the server; show it before
            // surfacing the failure.
            await refreshDataOnly()
            throw error
        }
        await refreshDataOnly()
        return ids
    }

    func updateSchedule(
        _ schedule: ScheduleSummary,
        fields: ScheduleFormFields,
        resetNextDate: Bool = false
    ) async throws {
        guard let syncClient else { throw BudgetStoreError.syncNotConfigured }
        try await syncClient.updateSchedule(
            schedule, fields: fields, resetNextDate: resetNextDate)
        await refreshDataOnly()
    }

    func deleteSchedule(_ schedule: ScheduleSummary) async throws {
        guard let syncClient else { throw BudgetStoreError.syncNotConfigured }
        try await syncClient.deleteSchedule(schedule)
        await refreshDataOnly()
    }
    
    func skipScheduleNextDate(_ schedule: ScheduleSummary) async throws {
        guard let syncClient else { throw BudgetStoreError.syncNotConfigured }
        try await syncClient.skipScheduleNextDate(schedule)
        await refreshDataOnly()
    }

    func postScheduleTransaction(_ schedule: ScheduleSummary, today: Bool) async throws {
        guard let syncClient else { throw BudgetStoreError.syncNotConfigured }
        try await syncClient.postScheduleTransaction(schedule, today: today)
        await refreshDataOnly()
    }

    func setScheduleCompleted(_ schedule: ScheduleSummary, completed: Bool) async throws {
        guard let syncClient else { throw BudgetStoreError.syncNotConfigured }
        try await syncClient.setScheduleCompleted(schedule, completed: completed)
        await refreshDataOnly()
    }

    func fetchScheduleTransactions(_ scheduleId: String) async -> [Transaction] {
        guard let database else { return [] }
        return (try? database.fetchTransactions(scheduleId: scheduleId)) ?? []
    }

    /// Link transactions to a schedule, or unlink them by passing nil.
    /// `transactions.schedule` is already a syncable field, so this needs no
    /// new write path.
    func linkTransactions(_ transactions: [Transaction], to scheduleId: String?) async throws {
        guard let database, let syncClient else { throw BudgetStoreError.syncNotConfigured }
        guard !transactions.isEmpty else { return }

        try database.setTransactionSchedule(
            transactionIds: transactions.map(\.id), scheduleId: scheduleId)

        let updated = transactions.map { transaction -> Transaction in
            var copy = transaction
            copy.schedule = scheduleId
            return copy
        }
        try await syncClient.updateTransactions(updated, changedFields: ["schedule"])
        await refreshDataOnly()
    }
    
    /// Scan transaction history for repeating payments.
    func discoverSchedules() async -> [ScheduleDiscovery.Proposal] {
        guard let database else { return [] }
        return await Self.runDiscovery(accounts: accounts, database: database)
    }

    /// The sweep is CPU-bound and would stutter the UI on the main actor.
    /// `nonisolated async` runs it on the generic executor without an ad-hoc
    /// detached-task hop; `BudgetDatabase` serialises its own reads through
    /// GRDB's queue, so calling it from here is safe.
    nonisolated private static func runDiscovery(
        accounts: [Account],
        database: BudgetDatabase
    ) async -> [ScheduleDiscovery.Proposal] {
        (try? ScheduleDiscovery.discover(
            accounts: accounts,
            loadCandidates: { accountId, notBefore in
                try database.fetchDiscoveryTransactions(
                    accountId: accountId, notBefore: notBefore)
            },
            latestDate: { try database.latestTransactionDate(accountId: $0) }))
            ?? []
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
        } catch is CancellationError {
            // Hosting view task cancelled (rapid month flips) — not an error.
        } catch {
            guard requestedBudgetMonth == month else { return }
            self.error = error.localizedDescription
        }
    }

    // MARK: - Budget Amounts

    /// Prior category-month rows used for Quick Assign suggestions. Reading
    /// history never changes the displayed month or introduces new storage.
    func budgetHistory(for category: CategoryBudget, monthCount: Int = 3) async -> [CategoryBudget] {
        guard let database, monthCount > 0 else { return [] }
        var result: [CategoryBudget] = []
        var month = category.month
        for _ in 0..<monthCount {
            guard let previous = Self.shiftBudgetMonth(month, by: -1) else { break }
            month = previous
            guard let budget = try? await database.fetchBudgetMonth(month: previous),
                  let priorCategory = budget.categoryBudgets.first(where: {
                      $0.categoryId == category.categoryId
                  }) else { continue }
            result.append(priorCategory)
        }
        return result
    }

    /// Shift a "yyyy-MM" month key. Also backs the budget tab's month picker
    /// (`BudgetView.shiftMonth`), so the format logic lives in one place.
    /// Pure computation, so it stays callable off the main actor.
    nonisolated static func shiftBudgetMonth(_ month: String, by offset: Int) -> String? {
        let parts = month.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]),
              let monthNumber = Int(parts[1]),
              let date = Calendar.current.date(from: DateComponents(
                  year: year, month: monthNumber, day: 1
              )),
              let shifted = Calendar.current.date(byAdding: .month, value: offset, to: date)
        else { return nil }
        let components = Calendar.current.dateComponents([.year, .month], from: shifted)
        guard let shiftedYear = components.year, let shiftedMonth = components.month else { return nil }
        return String(format: "%04d-%02d", shiftedYear, shiftedMonth)
    }

    /// Parse the budget edit field ("25.50") into cents. Negative amounts
    /// (intentional overdraw, as Actual's web client allows) are only valid
    /// where the caller opts in — a transfer, for instance, must stay
    /// non-negative or it would silently reverse direction.
    static func budgetAmountCents(from string: String, allowNegative: Bool = false) throws -> Int {
        guard let dollars = Double(string),
              let cents = Transaction.cents(fromDollars: dollars),
              allowNegative || cents >= 0 else {
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

    /// Move budgeted funds between categories (GH #128), nil meaning the
    /// month's "To Budget" pool on that side. Writes through the sync engine
    /// (optimistic local-first), then refetches the month so both categories'
    /// published Available figures recompute.
    func transferBudget(month: String, fromCategoryId: String?, toCategoryId: String?, amountCents: Int) async throws {
        guard let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }
        guard amountCents > 0 else {
            throw BudgetStoreError.transferAmountNotPositive
        }
        // Also rejects To Budget on both sides (nil == nil) — a no-op request.
        guard fromCategoryId != toCategoryId else {
            throw BudgetStoreError.transferCategoriesMatch
        }
        try await syncClient.transferBudget(
            month: month,
            fromCategoryId: fromCategoryId,
            toCategoryId: toCategoryId,
            amount: amountCents
        )
        await fetchBudgetMonth(month)
    }

    // MARK: - Notes

    /// Load the note for a category (GH #131) or account (GH #198), keyed by
    /// that row's id. Reported as `.unsupported` when no budget file is open,
    /// the file has no `notes` table, or the read fails — the note affordance
    /// hides itself in all three cases, which is the right outcome for each and
    /// beats surfacing a banner over a secondary field.
    func fetchNote(id: String) async -> EntityNote {
        guard let database else { return .unsupported }
        do {
            return try await database.fetchNote(id: id)
        } catch {
            logger.error("Failed to read note: \(error.localizedDescription, privacy: .public)")
            return .unsupported
        }
    }

    /// Save a note, syncing back to Actual (GH #131, #198). An empty string
    /// clears it. Throws so the caller can keep the editor open and show the
    /// failure rather than silently dropping what the user typed.
    func saveNote(id: String, note: String) async throws {
        guard let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }
        try await syncClient.setNote(id: id, note: note)
    }
    
    // MARK: - Rules

    /// Live rules in engine order (GH #222). Loaded on demand by the Rules
    /// screen rather than at budget load — most sessions never open it.
    @Published private(set) var rules: [Rule] = []
    /// Rules a schedule owns: editable, but not deletable, same as upstream.
    @Published private(set) var scheduleOwnedRuleIds: Set<String> = []
    /// False when the open budget file predates the `rules` table, which hides
    /// the whole feature rather than failing at save time.
    @Published private(set) var rulesSupported = false

    func loadRules() async {
        guard let database else {
            rules = []
            scheduleOwnedRuleIds = []
            rulesSupported = false
            return
        }
        do {
            rulesSupported = try database.rulesTableExists()
            rules = rulesSupported ? try await database.fetchRulesRanked() : []
            scheduleOwnedRuleIds = (try? database.scheduleOwnedRuleIds()) ?? []
        } catch {
            logger.error("loadRules failed: \(error.localizedDescription, privacy: .public)")
            rules = []
            scheduleOwnedRuleIds = []
        }
    }

    /// Create or update a rule. Validation mirrors upstream `rule-validate`:
    /// a rule needs at least one condition and one action, and every condition
    /// must use an operator its field supports.
    func saveRule(_ rule: Rule) async throws {
        guard let syncClient else { throw BudgetStoreError.syncNotConfigured }
        try Self.validate(rule)
        try await syncClient.saveRule(rule)
        await loadRules()
    }

    /// Delete a rule. Refuses when a schedule owns it, like upstream's
    /// `deleteRule`, which returns false rather than orphaning the schedule.
    func deleteRule(_ rule: Rule) async throws {
        guard let syncClient else { throw BudgetStoreError.syncNotConfigured }
        guard !scheduleOwnedRuleIds.contains(rule.id) else {
            throw BudgetStoreError.ruleOwnedBySchedule
        }
        try await syncClient.deleteRule(rule)
        await loadRules()
    }

    static func validate(_ rule: Rule) throws {
        guard !rule.conditions.isEmpty else { throw BudgetStoreError.ruleNeedsCondition }
        guard !rule.actions.isEmpty else { throw BudgetStoreError.ruleNeedsAction }
        guard rule.isSerializable else { throw BudgetStoreError.ruleNotSerializable }

        for condition in rule.conditions {
            guard RuleSchema.isValidOp(field: condition.field, op: condition.op) else {
                throw BudgetStoreError.ruleInvalidCondition(field: condition.field, op: condition.op)
            }
            // Upstream's Condition constructor rejects empty values for
            // non-nullable types, and empty arrays for oneOf/notOneOf.
            switch condition.op {
            case "oneOf", "notOneOf":
                guard condition.value.listValue?.isEmpty == false else {
                    throw BudgetStoreError.ruleEmptyValue(field: condition.field)
                }
            case "onBudget", "offBudget":
                break
            case "isbetween":
                // Upstream's parse asserts a `{num1, num2}` payload; anything
                // else makes `makeRule` return null and the whole rule vanish
                // from the web client.
                guard condition.value.betweenValue != nil else {
                    throw BudgetStoreError.ruleEmptyValue(field: condition.field)
                }
            default:
                let type = RuleSchema.fieldType(condition.field)
                if type == .number || type == .date || type == .boolean {
                    guard !condition.value.isNull else {
                        throw BudgetStoreError.ruleEmptyValue(field: condition.field)
                    }
                }
                // A date condition needs a full YYYY-MM-DD for the comparison
                // ops; `is` also accepts a month or a year, matching upstream's
                // parseDateString.
                if type == .date {
                    let digits = (condition.value.stringValue ?? "")
                        .replacingOccurrences(of: "-", with: "")
                    let allowed = condition.op == "is" ? [4, 6, 8] : [8]
                    guard allowed.contains(digits.count), Int(digits) != nil else {
                        throw BudgetStoreError.ruleEmptyValue(field: condition.field)
                    }
                }
                if ["contains", "doesNotContain", "matches", "hasTags", "hasAnyTag"].contains(condition.op) {
                    guard let text = condition.value.stringValue, !text.isEmpty else {
                        throw BudgetStoreError.ruleEmptyValue(field: condition.field)
                    }
                    // Upstream doesn't check this — a bad pattern just fails
                    // silently at apply time. Catching it here is the one place
                    // the user can still do something about it. Compile the
                    // lowercased pattern, which is what the engine will run.
                    if condition.op == "matches" {
                        // No timeout exists for NSRegularExpression, so a
                        // pathological pattern would wedge the sync actor it
                        // runs on. A length bound doesn't make that impossible,
                        // but it rules out the pasted-blob case; the web app has
                        // the same exposure.
                        guard text.count <= 500 else {
                            throw BudgetStoreError.ruleInvalidPattern(pattern: text)
                        }
                        guard (try? NSRegularExpression(pattern: text.lowercased())) != nil else {
                            throw BudgetStoreError.ruleInvalidPattern(pattern: text)
                        }
                    }
                }
            }
        }

        for action in rule.actions where action.op == "set" {
            guard let field = action.field, RuleSchema.fieldType(field) != nil else {
                throw BudgetStoreError.ruleInvalidAction
            }
            // Upstream: `account` may never be set to nothing.
            if field == "account", action.value.stringValue?.isEmpty != false {
                throw BudgetStoreError.ruleEmptyValue(field: field)
            }
        }
    }
    
    /// Names for everything a rule summary might reference.
    var ruleSummary: RuleSummary {
        let categories = categoryGroups.flatMap(\.categories)
        return RuleSummary(
            names: .init(
                payees: Dictionary(payees.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
                categories: Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
                categoryGroups: Dictionary(categoryGroups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
                accounts: Dictionary(accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            ),
            formatAmount: { [weak self] cents in self?.formatCurrency(cents) ?? "\(cents)" }
        )
    }

    // MARK: - Currency Formatting

    /// Format an amount in cents to a currency string using the budget's currency
    /// - Parameter cents: Amount in cents (e.g., 1050 = $10.50)
    /// - Returns: Formatted currency string (e.g., "$10.50")
    func formatCurrency(_ cents: Int) -> String {
        CurrencyAmountFormat.string(cents: cents, currencyCode: currencyCode,
                                    narrowSymbol: useNarrowCurrencySymbol)
    }

    /// Like `formatCurrency`, but rounded to whole units (e.g., "$1,051").
    /// Used for compact chart annotations where cents add noise.
    func formatCurrencyWholeUnits(_ cents: Int) -> String {
        CurrencyAmountFormat.string(cents: cents, currencyCode: currencyCode,
                                    narrowSymbol: useNarrowCurrencySymbol, wholeUnits: true)
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

