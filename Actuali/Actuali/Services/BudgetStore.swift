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
    case categoryUpdateFailed(String)
    case categoryGroupCreationFailed(String)
    case ruleNeedsCondition
    case ruleNeedsAction
    case ruleInvalidCondition(field: String, op: String)
    case ruleInvalidAction
    case ruleEmptyValue(field: String)
    case ruleInvalidPattern(pattern: String)
    case ruleOwnedBySchedule
    case ruleNotSerializable
    case bankSyncNotConfigured

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
        case .accountCreationFailed(let message):
            return "Failed to create account: \(message)"
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
        case .invalidCategoryName:
            return "Enter a category name"
        case .invalidCategoryGroupName:
            return "Enter a category group name"
        case .categoryCreationFailed(let message):
            return "Failed to create category: \(message)"
        case .categoryUpdateFailed(let message):
            return "Failed to update category: \(message)"
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
        case .bankSyncNotConfigured:
            return "SimpleFIN isn't set up yet. Connect it in More → Transactions & Automation first."
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
    private var categoryFundingTask: Task<Void, Never>?

    func enqueueCategoryFunding(
        savedTransactionId: String,
        defaults: UserDefaults
    ) {
        let previousTask = categoryFundingTask
        categoryFundingTask = Task { @MainActor [weak self] in
            _ = await previousTask?.result
            guard let self else { return }
            await CategoryFundingAutomation.process(
                savedTransactionId: savedTransactionId,
                using: self,
                defaults: defaults
            )
        }
    }
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
            if currentBudgetId != oldValue {
                creditCardConfigs = [:]
            }
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
    /// Accounts wired up to a bank feed, refreshed alongside the rest of the
    /// budget so the accounts tab knows which rows can be synced.
    @Published private(set) var bankSyncAccounts: [BankSyncAccount] = []
    /// Whether this device has claimed a SimpleFIN access key.
    @Published private(set) var isSimpleFINConfigured = SimpleFINCredentials.isConfigured
    /// True for the length of a bank sync, so the UI can show progress and
    /// keep a second sync from starting on top of the first.
    @Published private(set) var isBankSyncing = false

    /// The current calendar month's budget, tracked separately from
    /// `currentBudgetMonth` (which follows whatever month BudgetView is
    /// browsing) so the widget never publishes historical balances.
    var widgetBudgetMonth: BudgetMonth?

    /// Where publishWidgetSnapshot() writes; injectable for tests. nil when
    /// the build's provisioning lacks the app group.
    var widgetSnapshotStore: WidgetSnapshotStore? = .standard()

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

    /// Synced credit card configurations loaded from the preferences table (accountId -> CreditCardConfig).
    @Published var creditCardConfigs: [String: CreditCardConfig] = [:]

    /// Currency code for formatting (e.g., "USD", "EUR", "GBP")
    /// Persisted to UserDefaults, defaults to "USD"
    @Published var currencyCode: String = "USD" {
        didSet {
            UserDefaults.standard.set(currencyCode, forKey: "currencyCode")
            publishWidgetSnapshot()
        }
    }

    /// Number formatting follows Actual's synced `numberFormat` preference.
    /// It deliberately has no UserDefaults fallback: the budget's synced
    /// preference is the source of truth, with `.commaDot` as the Actual default.
    @Published var numberFormat: ActualNumberFormat = .commaDot {
        didSet {
            publishWidgetSnapshot()
        }
    }

    private static func currencyCodeCacheKey(for budgetId: String) -> String {
        "currencyCode.\(budgetId)"
    }

    private func cachedCurrencyCode(for budgetId: String) -> String? {
        UserDefaults.standard.string(forKey: Self.currencyCodeCacheKey(for: budgetId))
    }

    private func cacheCurrencyCode(_ code: String, for budgetId: String) {
        // Keep an explicit empty value too: it is Actual's meaningful "None"
        // preference, distinct from a budget we have never cached.
        UserDefaults.standard.set(code, forKey: Self.currencyCodeCacheKey(for: budgetId))
    }

    private func forgetCachedCurrencyCode(for budgetId: String) {
        UserDefaults.standard.removeObject(forKey: Self.currencyCodeCacheKey(for: budgetId))
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
        if let currentBudgetId {
            cacheCurrencyCode(code, for: currentBudgetId)
        }
        guard let syncClient else { return }
        do {
            try await syncClient.updateCurrencyCode(code)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// User-initiated number formatting changes use the same generic synced
    /// preference path as other Actual preferences. No local persistence is
    /// needed because the budget database is authoritative.
    func setNumberFormat(_ format: ActualNumberFormat) async {
        numberFormat = format
        guard let syncClient else { return }
        do {
            try await syncClient.setPreference(key: "numberFormat", value: format.rawValue)
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
            publishWidgetSnapshot()
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
            UserDefaults.standard.set(
                budgetDisplayStyle.rawValue,
                forKey: "budgetDisplayStyle"
            )
        }
    }

    /// Whether the Compact Budget view style shows its pinned monthly overview.
    /// This is independent of the Clean and Detailed summaries and defaults on.
    @Published var showCompactBudgetOverview: Bool = true {
        didSet {
            UserDefaults.standard.set(
                showCompactBudgetOverview,
                forKey: "showCompactBudgetOverview"
            )
        }
    }

    /// Whether the Compact Budget view style includes the Spent column.
    /// The narrower two-amount layout is the default.
    @Published var showCompactSpentColumn: Bool = false {
        didSet {
            UserDefaults.standard.set(
                showCompactSpentColumn,
                forKey: "showCompactSpentColumn"
            )
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

    /// Whether Budget rows show their compact category-status dot.
    /// Persisted to UserDefaults, defaults to on.
    @Published var showCategoryStatusDots: Bool = true {
        didSet {
            UserDefaults.standard.set(showCategoryStatusDots, forKey: "showCategoryStatusDots")
        }
    }

    /// Whether Budget shows the status filter strip above the category list.
    /// Persisted to UserDefaults, defaults to on. It costs a row of vertical
    /// space on a phone, so a budget that never needs the filters can reclaim
    /// it — hiding the strip drops any active filter with it.
    @Published var showBudgetCheckInStrip: Bool = true {
        didSet {
            UserDefaults.standard.set(showBudgetCheckInStrip, forKey: "showBudgetCheckInStrip")
        }
    }

    /// Whether the Detailed and Compact styles' group headers total their columns.
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
            publishWidgetSnapshot()
        }
    }

    /// Whether shaking the device toggles `hideBalances`.
    /// Persisted to UserDefaults, defaults to off (opt-in to avoid
    /// conflicting with Shake to Undo).
    @Published var shakeToHideBalances: Bool = false {
        didSet {
            UserDefaults.standard.set(shakeToHideBalances, forKey: "shakeToHideBalances")
        }
    }

    /// Changes only for enabled shake gestures, so view feedback is not
    /// coupled to every other way `hideBalances` can change.
    @Published private(set) var shakeFeedbackTrigger = false

    /// Whether displayed currency amounts omit their fractional digits.
    /// The underlying cent values remain unchanged; this is presentation only.
    @Published var hideDecimalPlaces: Bool = false {
        didSet {
            UserDefaults.standard.set(hideDecimalPlaces, forKey: "hideDecimalPlaces")
            publishWidgetSnapshot()
        }
    }

    /// Whether Budget hides categories with no budget left this month.
    /// Persisted to UserDefaults, defaults to off.
    @Published var hideZeroBudgetCategories: Bool = false {
        didSet {
            UserDefaults.standard.set(hideZeroBudgetCategories, forKey: "hideZeroBudgetCategories")
        }
    }

    /// Whether hidden categories and groups are included on the Budget tab.
    /// Persisted locally so an item stays reachable until the user turns the
    /// view option off again.
    @Published var showHiddenCategories: Bool = false {
        didSet {
            UserDefaults.standard.set(showHiddenCategories, forKey: "showHiddenCategories")
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

    /// Whether transaction lists hide transactions locked by reconciliation.
    /// Persisted to UserDefaults, defaults to off (GH #355).
    @Published var hideReconciledTransactions: Bool = false {
        didSet {
            UserDefaults.standard.set(hideReconciledTransactions, forKey: "hideReconciledTransactions")
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
        let visible = categories.filter { !$0.isEffectivelyHidden }
        let filtered = hideZeroBudgetCategories
            ? visible.filter { $0.available != 0 }
            : visible
        return showHiddenCategories
            ? filtered + categories.filter(\.isEffectivelyHidden)
            : filtered
    }

    /// Closed accounts the Accounts list should show — none when the hide
    /// toggle is on. A view filter only: the All Accounts total still counts
    /// closed accounts, so hiding them can't quietly change the net worth on
    /// screen.
    var visibleClosedAccounts: [Account] {
        hideClosedAccounts ? [] : accounts.filter(\.closed)
    }

    static let hiddenBalanceText = "\u{2022}\u{2022}\u{2022}\u{2022}"

    func displayBalance(_ cents: Int) -> String {
        guard !hideBalances else { return Self.hiddenBalanceText }
        return hideDecimalPlaces ? formatCurrencyWholeUnits(cents) : formatCurrency(cents)
    }

    func displayBalanceWholeUnits(_ cents: Int) -> String {
        hideBalances ? Self.hiddenBalanceText : formatCurrencyWholeUnits(cents)
    }

    func displaySpentCaption(_ spentCents: Int) -> String {
        guard !hideBalances else { return Self.hiddenBalanceText }
        let magnitude = spentCents > 0 ? spentCents : -spentCents
        let text = hideDecimalPlaces
            ? formatCurrencyWholeUnits(magnitude)
            : formatCurrency(magnitude)
        return spentCents > 0
            ? "+\(text)"
            : text
    }

    func handleDeviceShake() {
        guard shakeToHideBalances else { return }
        hideBalances.toggle()
        shakeFeedbackTrigger.toggle()
    }

    @Published var recordPayeeLocations: Bool = true {
        didSet {
            UserDefaults.standard.set(recordPayeeLocations, forKey: "recordPayeeLocations")
        }
    }

    @Published var schedulePostNotice: String?

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

    var defaultDashboardPageId: String? {
        get {
            guard let budgetId = currentBudgetId else { return nil }
            return UserDefaults.standard.string(forKey: "defaultDashboardPageId_\(budgetId)")
        }
        set {
            guard let budgetId = currentBudgetId else { return }
            if let value = newValue {
                UserDefaults.standard.set(value, forKey: "defaultDashboardPageId_\(budgetId)")
            } else {
                UserDefaults.standard.removeObject(forKey: "defaultDashboardPageId_\(budgetId)")
            }
            objectWillChange.send()
        }
    }

    var lastViewedBudgetMonth: String? {
        get {
            guard let budgetId = currentBudgetId else { return nil }
            return UserDefaults.standard.string(forKey: "lastViewedBudgetMonth_\(budgetId)")
        }
        set {
            guard let budgetId = currentBudgetId else { return }
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: "lastViewedBudgetMonth_\(budgetId)")
            } else {
                UserDefaults.standard.removeObject(forKey: "lastViewedBudgetMonth_\(budgetId)")
            }
        }
    }

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

    var creditCardStatementDays: [String: Int] {
        creditCardConfigs.mapValues(\.statementDay)
    }

    var creditCardDueOffsets: [String: Int] {
        creditCardConfigs.mapValues(\.dueOffsetDays)
    }

    var creditCardLimits: [String: Int] {
        creditCardConfigs.compactMapValues(\.limit)
    }

    var activeCreditCardStatementDays: [String: Int] {
        let openAccountIds = Set(accounts.filter { !$0.closed }.map(\.id))
        return creditCardStatementDays.filter { openAccountIds.contains($0.key) }
    }

    func setCreditCard(
        accountId: String,
        statementDay: Int?,
        dueOffsetDays: Int = CreditCardCycle.defaultDueOffsetDays,
        limit: Int?
    ) async {
        guard currentBudgetId != nil else { return }
        let previous = creditCardConfigs[accountId]
        let config: CreditCardConfig? = statementDay.map {
            CreditCardConfig(statementDay: $0, dueOffsetDays: dueOffsetDays, limit: limit)
        }
        creditCardConfigs[accountId] = config
        guard let syncClient else {
            creditCardConfigs[accountId] = previous
            error = "Credit card settings need sync configured for this budget."
            return
        }
        do {
            try await syncClient.setCreditCardConfig(accountId: accountId, config: config)
        } catch {
            creditCardConfigs[accountId] = previous
            self.error = error.localizedDescription
        }
    }

    func creditCardCycle(for accountId: String) -> CreditCardCycle? {
        guard let day = creditCardStatementDays[accountId] else { return nil }
        return CreditCardCycle(
            statementDay: day,
            dueOffsetDays: creditCardDueOffsets[accountId] ?? CreditCardCycle.defaultDueOffsetDays
        )
    }

    func activeCreditCardCycle(for accountId: String) -> CreditCardCycle? {
        guard let account = accounts.first(where: { $0.id == accountId }), !account.closed else { return nil }
        return creditCardCycle(for: accountId)
    }

    func availableCredit(for accountId: String) -> Int? {
        guard let limit = creditCardLimits[accountId],
              activeCreditCardCycle(for: accountId) != nil,
              let account = accounts.first(where: { $0.id == accountId })
        else { return nil }
        return limit + account.balance
    }

    func resolveAccountId(hint: String) async -> String? {
        Self.resolveAccountId(
            hint: hint,
            accounts: await accountsForIntent(),
            cardMappings: cardAccountMappings
        )
    }

    nonisolated static func resolveAccountId(
        hint: String,
        accounts: [Account],
        cardMappings: [String: String]
    ) -> String? {
        let trimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let activeAccounts = accounts.filter { !$0.closed }
        guard !activeAccounts.isEmpty else { return nil }
        let activeIds = Set(activeAccounts.map(\.id))

        let mappingsByLongestKey = cardMappings
            .map { (key: $0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                    accountId: $0.value) }
            .filter { !$0.key.isEmpty }
            .sorted { $0.key.count != $1.key.count ? $0.key.count > $1.key.count : $0.key < $1.key }
        for mapping in mappingsByLongestKey
        where trimmed.contains(mapping.key) && activeIds.contains(mapping.accountId) {
            return mapping.accountId
        }

        if let exact = activeAccounts.first(where: { $0.name.lowercased() == trimmed }) {
            return exact.id
        }

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
            guard database !== oldValue else { return }
            schedulePoster = nil
        }
    }

    var databaseForLogger: BudgetDatabase? { database }

    static let locationProvider = LocationProvider()

    func fetchNearbyPayees(latitude: Double, longitude: Double) async -> [NearbyPayee] {
        guard let database else { return [] }
        do {
            return try await database.fetchNearbyPayees(latitude: latitude, longitude: longitude)
        } catch {
            logger.error("fetchNearbyPayees failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func fetchCommonPayees() async -> [Payee] {
        guard let database else { return [] }

        do {
            return try await database.fetchCommonPayees()
        } catch {
            logger.error(
                "fetchCommonPayees failed: \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

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

    func fetchPayeesWithLocations() async -> [PayeeLocationSummary] {
        guard let database else { return [] }
        do {
            return try await database.fetchPayeesWithLocations()
        } catch {
            logger.error("fetchPayeesWithLocations failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func fetchPayeeLocations(payeeId: String) async -> [PayeeLocation] {
        guard let database else { return [] }
        do {
            return try await database.fetchPayeeLocations(payeeId: payeeId)
        } catch {
            logger.error("fetchPayeeLocations failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

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
    func seedDebugPayeeLocations(payeeName: String) async {
        guard let database,
              let payees = try? await database.fetchPayees(),
              let payee = payees.first(where: {
                  !$0.tombstone && $0.name == payeeName
              }) else {
            logger.error("seedDebugPayeeLocations: payee \(payeeName, privacy: .public) not found")
            return
        }
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

    func ensureBudgetReady() async {
        if syncClient != nil { return }
        if let loadTask {
            await loadTask.value
            if database != nil { return }
        }
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
    var isViewingBackup: Bool { backups.contains(where: \.isLatest) }
    @Published private(set) var syncDetachedByRestore = false
    private lazy var backupService = BackupService(fileManager: fileManager)
    private var loadTask: Task<Void, Never>?

    struct RemoteBudget: Identifiable {
        let id: String
        let name: String
        let groupId: String?
        let isEncrypted: Bool
    }

    // MARK: - Initialization

    @MainActor static let shared = BudgetStore()

    static func previewInstance() -> BudgetStore {
        BudgetStore(forPreview: ())
    }

    #if DEBUG
    func configureForTesting(database: BudgetDatabase, syncClient: SyncClient) {
        self.database = database
        self.syncClient = syncClient
        subscribeToSyncState()
    }

    func simulateFailedInitialLoadForTesting() {
        loadTask = Task {}
    }

    func setServerClientForTesting(_ client: ActualServerClient) {
        serverClient = client
    }

    func setSimpleFINClientForTesting(_ client: SimpleFINClient) {
        simpleFINClient = client
    }

    func setSimpleFINAccessKeyForTesting(_ accessKey: SimpleFINAccessKey?) {
        simpleFINAccessKeyProvider = { accessKey }
    }

    func setAppleWalletStoreForTesting(_ store: any AppleWalletReading) {
        appleWalletStore = store
    }

    func configureAppleWalletLinksForTesting(defaults: UserDefaults, budgetId: String) {
        appleWalletLinkDefaults = defaults
        _currentBudgetId = Published(initialValue: budgetId)
    }

    func setFileManagerForTesting(_ manager: BudgetFileManager) {
        fileManager = manager
        backupService = BackupService(fileManager: manager)
    }

    var isSyncConfiguredForTesting: Bool { syncClient != nil }
    var budgetMonthsFetchedForTesting: (() async -> Void)?

    func closeDatabaseForTesting() {
        syncStateCancellable?.cancel()
        syncStateCancellable = nil
        syncClient = nil
        database = nil
    }
    #endif

    private init() {
        let defaults = UserDefaults.standard
        func persistedBool(_ key: String, default defaultValue: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
        }

        _serverURL = Published(
            initialValue: defaults.string(forKey: "serverURL") ?? "")
        _fallbackServerURL = Published(
            initialValue: defaults.string(forKey: "fallbackServerURL") ?? "")
        customHeaders = Self.loadPersistedCustomHeaders()
        _currentBudgetId = Published(
            initialValue: defaults.string(forKey: "currentBudgetId"))
        _currencyCode = Published(
            initialValue: defaults.string(forKey: "currencyCode") ?? "USD")
        _useNarrowCurrencySymbol = Published(
            initialValue: persistedBool("useNarrowCurrencySymbol", default: false))
        if let raw = defaults.string(forKey: "appearanceMode"),
           let mode = AppearanceMode(rawValue: raw) {
            _appearanceMode = Published(initialValue: mode)
        }
        _startTab = Published(initialValue: StartTab.persisted)
        _budgetDisplayStyle = Published(initialValue: BudgetDisplayStyle(
            rawValue: defaults.string(forKey: "budgetDisplayStyle") ?? ""
        ) ?? .clean)
        _showCompactBudgetOverview = Published(
            initialValue: persistedBool("showCompactBudgetOverview", default: true))
        _showCompactSpentColumn = Published(
            initialValue: persistedBool("showCompactSpentColumn", default: false))
        _transactionDisplayMode = Published(initialValue: TransactionDisplayMode.persisted)
        _uncategorizedTapAction = Published(initialValue: UncategorizedTapAction.persisted)
        _showBudgetProgressBars = Published(
            initialValue: persistedBool("showBudgetProgressBars", default: true))
        _showCategoryStatusDots = Published(
            initialValue: persistedBool("showCategoryStatusDots", default: true))
        _showGroupTotals = Published(
            initialValue: persistedBool("showGroupTotals", default: true))
        _showBudgetCheckInStrip = Published(
            initialValue: persistedBool("showBudgetCheckInStrip", default: true))
        _showOverspentBadge = Published(
            initialValue: persistedBool("showOverspentBadge", default: true))
        _conventionalAmountEntry = Published(
            initialValue: persistedBool("conventionalAmountEntry", default: false))
        _hideBalances = Published(
            initialValue: persistedBool("hideBalances", default: false))
        _shakeToHideBalances = Published(
            initialValue: persistedBool("shakeToHideBalances", default: false))
        _hideDecimalPlaces = Published(
            initialValue: persistedBool("hideDecimalPlaces", default: false))
        _recordPayeeLocations = Published(
            initialValue: persistedBool("recordPayeeLocations", default: true))
        _hideZeroBudgetCategories = Published(initialValue: defaults
            .bool(forKey: "hideZeroBudgetCategories"))
        _showHiddenCategories = Published(initialValue: defaults
            .bool(forKey: "showHiddenCategories"))
        _hideClearedTransactions = Published(initialValue: defaults
            .bool(forKey: "hideClearedTransactions"))
        _hideReconciledTransactions = Published(initialValue: defaults
            .bool(forKey: "hideReconciledTransactions"))
        _hideClosedAccounts = Published(initialValue: defaults
            .bool(forKey: "hideClosedAccounts"))

        let token = loadAndMigrateAuthToken()
        if let budgetId = currentBudgetId, fileManager.budgetExists(budgetId) {
            isInitialSyncing = true
            loadTask = Task {
                if let token { await configureSavedSession(token: token) }
                await loadLocalBudget(budgetId)
                await syncOnForeground()
                isInitialSyncing = false
            }
        } else if let token {
            Task { await configureSavedSession(token: token) }
        }
    }

    private func configureSavedSession(token: String) async {
        try? await serverClient.configure(
            serverURL: serverURL,
            fallbackServerURL: Self.normalizedServerURL(fallbackServerURL)
        )
        await serverClient.setToken(token)
        isConnected = true
    }

    private init(forPreview: Void) {}

    // MARK: - Custom Headers

    private static let customHeadersKey = "customHeaders"

    private static func loadPersistedCustomHeaders() -> [CustomHeader] {
        guard let json = Keychain.get(for: customHeadersKey),
              let data = json.data(using: .utf8),
              let headers = try? JSONDecoder().decode([CustomHeader].self, from: data) else {
            return []
        }
        return headers
    }

    private func persistCustomHeaders() {
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
            applyCustomHeadersToClient()
        } catch {
            self.error = error.localizedDescription
            isLoading = false
            return
        }

        isLoading = false
    }

    func updateServerConnection(
        serverURL newServerURL: String,
        fallbackServerURL newFallbackServerURL: String
    ) async -> Bool {
        let normalized = Self.normalizedServerURL(newServerURL)
        let normalizedFallback = Self.normalizedServerURL(newFallbackServerURL)
        guard !normalized.isEmpty else {
            error = "Please enter a server URL"
            return false
        }
        guard Self.isValidServerURL(normalized) else {
            error = ActualServerError.invalidURL.localizedDescription
            return false
        }
        guard normalizedFallback.isEmpty || Self.isValidServerURL(normalizedFallback) else {
            error = ActualServerError.invalidFallbackURL.localizedDescription
            return false
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        let previousServerURL = serverURL
        let previousFallbackServerURL = fallbackServerURL
        do {
            if normalized != previousServerURL {
                try await serverClient.configure(serverURL: normalized)
                do {
                    _ = try await serverClient.fetchLoginMethods()
                } catch let probeError as ActualServerError where probeError.isConnectionFailure {
                    try? await serverClient.configure(
                        serverURL: previousServerURL,
                        fallbackServerURL: previousFallbackServerURL
                    )
                    self.error = probeError.localizedDescription
                    return false
                } catch {
                }
            }
            try await serverClient.configure(
                serverURL: normalized,
                fallbackServerURL: normalizedFallback
            )
            serverURL = normalized
            fallbackServerURL = normalizedFallback
            refreshPayeeLocationSupport()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    static func normalizedServerURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.range(of: "^[A-Za-z][A-Za-z0-9+\\-.]*://", options: .regularExpression) != nil {
            return trimmed
        }
        return "https://" + trimmed
    }

    private nonisolated static func isValidServerURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw) else { return false }
        return url.scheme != nil && url.host != nil
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

    private static let passwordOnlyLoginMethods = [
        LoginMethod(method: "password", displayName: "Password", active: 1)
    ]

    func checkLoginMethods() async {
        do {
            availableLoginMethods = try await serverClient.fetchLoginMethods()
        } catch ActualServerError.authProxyBlocked {
            error = ActualServerError.authProxyBlocked.localizedDescription
            availableLoginMethods = Self.passwordOnlyLoginMethods
        } catch let probeError as ActualServerError where probeError.isConnectionFailure {
            error = probeError.localizedDescription
            availableLoginMethods = Self.passwordOnlyLoginMethods
        } catch {
            logger.error("Failed to fetch login methods: \(error.localizedDescription, privacy: .public)")
            availableLoginMethods = Self.passwordOnlyLoginMethods
        }
        if supportsOpenIDLogin {
            ownerExists = await serverClient.fetchOwnerCreated()
        }
    }

    func loginWithOpenID(firstTimePassword: String?) async {
        isLoading = true
        error = nil

        do {
            let authURL = try await serverClient.beginOpenIDLogin(
                returnURL: OpenIDAuthenticator.returnURL,
                firstTimePassword: firstTimePassword
            )
            guard let authenticator = OpenIDAuthenticator.make() else {
                throw OpenIDAuthError.noWindow
            }
            let token = try await authenticator.authenticate(authorizationURL: authURL)

            await serverClient.setToken(token)
            try? Keychain.set(token, for: "authToken")
            isConnected = true
            await fetchRemoteBudgets()
        } catch OpenIDAuthError.cancelled {
        } catch {
            self.error = error.localizedDescription
            isConnected = false
        }

        isLoading = false
    }

    func logout(clearLocalData: Bool = true) {
        Task { await serverClient.setToken(nil) }
        try? Keychain.remove(for: "authToken")
        UserDefaults.standard.removeObject(forKey: "authToken")

        closeCurrentBudget()

        if clearLocalData {
            for local in fileManager.listLocalBudgets() {
                if let fileId = local.cloudFileId {
                    try? EncryptionKeyManager.remove(fileId: fileId)
                }
                try? fileManager.deleteBudget(local.id)
                forgetCachedCurrencyCode(for: local.id)
                forgetAppleWalletLinks(for: local.id)
            }

            try? SimpleFINCredentials.clear()
            isSimpleFINConfigured = false
        }

        isConnected = false
        remoteBudgets = []
        availableLoginMethods = []
        ownerExists = true
    }

    private func closeCurrentBudget() {
        syncStateCancellable?.cancel()
        syncStateCancellable = nil
        syncClient = nil
        database = nil

        backups = []
        syncDetachedByRestore = false
        currentBudgetId = nil
        requestedBudgetMonth = nil
        currentBudgetMonth = nil
        widgetBudgetMonth = nil
        accounts = []
        transactions = []
        uncategorizedCount = 0
        categoryGroups = []
        payees = []
        lastSyncTime = nil
        syncState = .idle
        isInitialSyncing = false
        dataVersion += 1
        clearWidgetSnapshot()
    }

    // MARK: - Budget Deletion

    func removeLocalBudget(cloudFileId: String) async {
        try? EncryptionKeyManager.remove(fileId: cloudFileId)

        guard let local = fileManager.listLocalBudgets().first(
            where: { $0.cloudFileId == cloudFileId }
        ) else { return }

        if local.id == currentBudgetId {
            await flushPendingSync()
            closeCurrentBudget()
        }

        try? fileManager.deleteBudget(local.id)
        forgetCachedCurrencyCode(for: local.id)
        forgetAppleWalletLinks(for: local.id)
    }

    func deleteServerBudget(_ remoteBudget: RemoteBudget) async -> String? {
        do {
            try await serverClient.deleteFile(fileId: remoteBudget.id)
        } catch ActualServerError.fileNotFound {
        } catch {
            return error.localizedDescription
        }
        await removeLocalBudget(cloudFileId: remoteBudget.id)
        remoteBudgets.removeAll { $0.id == remoteBudget.id }
        return nil
    }

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
        #if DEBUG
        if CommandLine.arguments.contains("-connectedServerSettings") { return }
        #endif
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

        syncStateCancellable?.cancel()
        syncStateCancellable = nil
        syncClient = nil
        database = nil

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

            var zipData = try await serverClient.downloadFile(fileId: remoteBudget.id)

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
            NewTransactionDetector.forgetWatermark(budgetId: metadata.id)
            await loadLocalBudget(metadata.id)
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
        downloadingBudgetId = nil

        if opened { await runInitialSync() }
    }

    private func runInitialSync() async {
        defer { isInitialSyncing = false }
        guard syncClient != nil else { return }
        await sync()
    }

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
        return error
    }

    nonisolated static func budgetNameError(_ name: String, existingNames: [String]) -> String? {
        if name.isEmpty { return "Budget name cannot be blank" }
        if name.count > 100 { return "Budget name is too long (max length 100)" }
        if existingNames.contains(name) { return "\u{201C}\(name)\u{201D} already exists" }
        return nil
    }

    func createBudget(named rawName: String) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingNames = remoteBudgets.map(\.name)
            + fileManager.listLocalBudgets().compactMap(\.budgetName)
        if let message = Self.budgetNameError(name, existingNames: existingNames) {
            error = message
            return
        }
        guard let templateURL = Bundle.main.url(forResource: "blank-budget", withExtension: "sqlite") else {
            error = "The blank budget template is missing from the app bundle."
            return
        }

        isLoading = true
        error = nil

        var registeredOnServer = false
        var uploadOutcomeUnknown = false

        do {
            let metadata = try fileManager.createBudget(named: name, templateURL: templateURL)
            let cloudFileId = UUID().uuidString.lowercased()
            var uploadStarted = false
            func saveRegistration(groupId: String) throws {
                let registered = BudgetMetadata(
                    id: metadata.id,
                    budgetName: name,
                    cloudFileId: cloudFileId,
                    groupId: groupId,
                    resetClock: nil,
                    lastUploaded: Self.yearMonthDayFormatter.string(from: Date()),
                    encryptKeyId: nil
                )
                try JSONEncoder().encode(registered)
                    .write(to: fileManager.metadataPath(for: metadata.id))
            }
            do {
                let zipData = try fileManager.makeUploadArchive(for: metadata.id)
                uploadStarted = true
                let groupId = try await serverClient.uploadFile(
                    zipData: zipData, fileId: cloudFileId, name: name
                )
                registeredOnServer = true
                try saveRegistration(groupId: groupId)
            } catch {
                let uploadError = error
                let files: [ListFilesResponse.RemoteFile]?
                if uploadStarted {
                    files = try? await serverClient.listFiles()
                } else {
                    files = []
                }
                if let remote = files?.first(where: { $0.fileId == cloudFileId }) {
                    registeredOnServer = true
                    guard let groupId = remote.groupId else { throw uploadError }
                    try saveRegistration(groupId: groupId)
                } else {
                    uploadOutcomeUnknown = files == nil
                    try? fileManager.deleteBudget(metadata.id)
                    throw uploadError
                }
            }

            syncStateCancellable?.cancel()
            syncStateCancellable = nil
            syncClient = nil
            database = nil

            currentBudgetId = metadata.id
            await loadLocalBudget(metadata.id)
            let loadError = error
            await fetchRemoteBudgets()
            if let loadError { self.error = loadError }
        } catch {
            if registeredOnServer {
                await fetchRemoteBudgets()
                self.error = """
                    \u{201C}\(name)\u{201D} was created on your server, but couldn't be finished on this device: \(error.localizedDescription) Select it in Budget Selection to download it.
                    """
            } else if uploadOutcomeUnknown {
                self.error = """
                    The connection stopped before Actuali received the upload result. Reopen Connection & Data before you try again.
                    """
            } else {
                self.error = error.localizedDescription
            }
        }

        isLoading = false
    }

    func loadLocalBudget(_ budgetId: String) async {
        isLoading = true
        error = nil
        let monthRequestGenerationBeforeLoad = budgetMonthRequestGeneration
        var published = false

        var db: BudgetDatabase?
        do {
            let dbPath = fileManager.databasePath(for: budgetId)
            let openedDb = try BudgetDatabase(path: dbPath)
            db = openedDb
            database = openedDb

            let fetchedCurrencyCode = try await openedDb.fetchCurrencyCode()
            let fetchedNumberFormat = try await openedDb.fetchPreference(id: "numberFormat")
            let fetchedUpcomingLength = try await openedDb.fetchUpcomingScheduledTransactionLength()
            let fetchedCreditCards = try await openedDb.fetchCreditCardConfigs()
            let fetchedAccounts = try await openedDb.fetchAccounts()
            let fetchedTransactions = try await openedDb.fetchTransactions()
            let fetchedUncategorizedCount = try await openedDb.fetchUncategorizedCount()
            let fetchedGroups = try await openedDb.fetchCategoryGroups()
            let fetchedPayees = try await openedDb.fetchPayees()
            let currentMonth = currentMonthString()
            let displayedMonth = budgetMonthRequestGeneration == monthRequestGenerationBeforeLoad
                ? lastViewedBudgetMonth ?? currentMonth
                : requestedBudgetMonth ?? lastViewedBudgetMonth ?? currentMonth
            let fetchedBudgetMonth = try await openedDb.fetchBudgetMonth(month: displayedMonth)
            let fetchedWidgetBudgetMonth = displayedMonth == currentMonth
                ? fetchedBudgetMonth
                : try await openedDb.fetchBudgetMonth(month: currentMonth)
            #if DEBUG
            await budgetMonthsFetchedForTesting?()
            #endif
            let fetchedGoalTemplatesFlag = try await openedDb.fetchPreference(
                id: "flags.goalTemplatesEnabled") == "true"
            let fetchedGoalTemplatesUIFlag = try await openedDb.fetchPreference(
                id: "flags.goalTemplatesUIEnabled") == "true"

            guard database === openedDb else { return }

            if let fetchedCurrencyCode {
                currencyCode = fetchedCurrencyCode
                cacheCurrencyCode(fetchedCurrencyCode, for: budgetId)
            } else if let cached = cachedCurrencyCode(for: budgetId) {
                currencyCode = cached
            }

            if let fetchedNumberFormat,
               let parsedNumberFormat = ActualNumberFormat(rawValue: fetchedNumberFormat) {
                numberFormat = parsedNumberFormat
            } else {
                numberFormat = .commaDot
            }
            
            upcomingScheduledTransactionLength = fetchedUpcomingLength

            var legacyConfigs: [String: CreditCardConfig] = [:]
            let legacyDays = UserDefaults.standard.dictionary(forKey: "creditCardStatementDays_\(budgetId)") as? [String: Int] ?? [:]
            let legacyOffsets = UserDefaults.standard.dictionary(forKey: "creditCardDueOffsets_\(budgetId)") as? [String: Int] ?? [:]
            let legacyLimits = UserDefaults.standard.dictionary(forKey: "creditCardLimits_\(budgetId)") as? [String: Int] ?? [:]
            for (accountId, statementDay) in legacyDays where fetchedCreditCards[accountId] == nil {
                legacyConfigs[accountId] = CreditCardConfig(
                    statementDay: statementDay,
                    dueOffsetDays: legacyOffsets[accountId] ?? CreditCardCycle.defaultDueOffsetDays,
                    limit: legacyLimits[accountId]
                )
            }
            creditCardConfigs = fetchedCreditCards.merging(legacyConfigs) { synced, _ in synced }
            
            accounts = fetchedAccounts
            transactions = fetchedTransactions
            uncategorizedCount = fetchedUncategorizedCount
            categoryGroups = fetchedGroups
            payees = fetchedPayees
            if budgetMonthRequestGeneration == monthRequestGenerationBeforeLoad {
                requestedBudgetMonth = displayedMonth
                currentBudgetMonth = fetchedBudgetMonth
            }
            widgetBudgetMonth = fetchedWidgetBudgetMonth
            goalTemplatesEnabled = fetchedGoalTemplatesFlag
            goalTemplatesUIEnabled = fetchedGoalTemplatesUIFlag
            dataVersion += 1
            publishWidgetSnapshot()
            published = true

            await loadBankSyncAccounts()

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

                if let syncClient {
                    var allWritten = true
                    for (accountId, config) in legacyConfigs {
                        do {
                            try await syncClient.setCreditCardConfig(accountId: accountId, config: config)
                        } catch {
                            allWritten = false
                            logger.error("Credit card migration failed for \(accountId, privacy: .public): \(error.localizedDescription)")
                        }
                    }
                    if allWritten {
                        for prefix in ["creditCardStatementDays_", "creditCardDueOffsets_", "creditCardLimits_"] {
                            UserDefaults.standard.removeObject(forKey: prefix + budgetId)
                        }
                    }
                }
            }

            refreshPayeeLocationSupport()

        } catch {
            guard db == nil || database === db else { return }
            if !published {
                syncStateCancellable?.cancel()
                syncStateCancellable = nil
                syncClient = nil
                requestedBudgetMonth = nil
                currentBudgetMonth = nil
                widgetBudgetMonth = nil
                accounts = []
                transactions = []
                uncategorizedCount = 0
                categoryGroups = []
                payees = []
                dataVersion += 1
                clearWidgetSnapshot()
            }
            self.error = "Failed to load budget: \(error.localizedDescription)"
        }

        isLoading = false
    }

    private func refreshPayeeLocationSupport() {
        let capturedURL = serverURL
        let key = "payeeLocationWritesEnabled_\(capturedURL)"
        payeeLocationWritesEnabled = UserDefaults.standard.bool(forKey: key)
        Task { [weak self] in
            guard let self else { return }
            guard let version = await self.serverClient.fetchServerVersion() else {
                return
            }
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

    func loadDemoData(tracking: Bool = false) async {
        logout(clearLocalData: false)
        do {
            try DemoDataSeeder.seed(tracking: tracking)
            currentBudgetId = DemoDataSeeder.budgetId
            await loadLocalBudget(DemoDataSeeder.budgetId)
            self.error = nil
        } catch {
            self.error = "Failed to seed demo data: \(error.localizedDescription)"
        }
    }

    private func refreshDataOnly() async {
        guard let database else { return }
        let budgetId = currentBudgetId
        let currencyCodeBefore = currencyCode
        let numberFormatBefore = numberFormat
        let creditCardsBefore = creditCardConfigs
        do {
            let fetchedAccounts = try await database.fetchAccounts()
            let fetchedTransactions = try await database.fetchTransactions()
            let fetchedUncategorizedCount = try await database.fetchUncategorizedCount()
            let fetchedGroups = try await database.fetchCategoryGroups()
            let fetchedPayees = try await database.fetchPayees()
            let currentMonth = currentMonthString()
            let displayedMonth = requestedBudgetMonth ?? currentMonth
            let fetchedBudgetMonth = try await database.fetchBudgetMonth(month: displayedMonth)
            let fetchedWidgetBudgetMonth: BudgetMonth
            if displayedMonth == currentMonth {
                fetchedWidgetBudgetMonth = fetchedBudgetMonth
            } else {
                fetchedWidgetBudgetMonth = try await database.fetchBudgetMonth(month: currentMonth)
            }
            let fetchedUpcomingLength = try await database.fetchUpcomingScheduledTransactionLength()
            let fetchedCreditCards = try await database.fetchCreditCardConfigs()
            let fetchedCurrencyCode = try await database.fetchCurrencyCode()
            let fetchedNumberFormat = try await database.fetchPreference(id: "numberFormat")
            let fetchedGoalTemplatesFlag = try await database.fetchPreference(
                id: "flags.goalTemplatesEnabled") == "true"
            let fetchedGoalTemplatesUIFlag = try await database.fetchPreference(
                id: "flags.goalTemplatesUIEnabled") == "true"

            guard self.database === database, self.currentBudgetId == budgetId else { return }

            if creditCardConfigs == creditCardsBefore {
                creditCardConfigs = fetchedCreditCards
            }

            accounts = fetchedAccounts
            transactions = fetchedTransactions
            uncategorizedCount = fetchedUncategorizedCount
            categoryGroups = fetchedGroups
            payees = fetchedPayees
            if requestedBudgetMonth == displayedMonth {
                currentBudgetMonth = fetchedBudgetMonth
            }
            widgetBudgetMonth = fetchedWidgetBudgetMonth
            upcomingScheduledTransactionLength = fetchedUpcomingLength
            goalTemplatesEnabled = fetchedGoalTemplatesFlag
            goalTemplatesUIEnabled = fetchedGoalTemplatesUIFlag
            if let fetchedCurrencyCode, currencyCode == currencyCodeBefore {
                currencyCode = fetchedCurrencyCode
                if let budgetId {
                    cacheCurrencyCode(fetchedCurrencyCode, for: budgetId)
                }
            }
            if let fetchedNumberFormat,
               let parsedNumberFormat = ActualNumberFormat(rawValue: fetchedNumberFormat),
               numberFormat == numberFormatBefore {
                numberFormat = parsedNumberFormat
            }
            dataVersion += 1

            await loadSchedules()
            await loadBankSyncAccounts()
            publishWidgetSnapshot()
        } catch is CancellationError {
        } catch {
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

        await loadLocalBudget(budgetId)
        await refreshBackups()
        isLoading = false
    }

    func backupFileURL(_ backupId: String) -> URL? {
        guard let budgetId = currentBudgetId else { return nil }
        return fileManager.backupPath(for: budgetId, name: backupId)
    }

    func revertToLatest() async {
        await restoreBackup(Backup.latest.id)
    }

    // MARK: - Payees

    func findOrCreatePayee(name: String) async throws -> Payee {
        if let existing = payees.first(where: { $0.name.lowercased() == name.lowercased() }) {
            return existing
        }

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
        payees.append(newPayee)
        return newPayee
    }

    // MARK: - Accounts

    @discardableResult
    func createAccount(name: String, offBudget: Bool, startingBalanceCents: Int) async throws -> Account {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw BudgetStoreError.invalidAccountName
        }
        guard let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }

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

        await refreshDataOnly()
        return account
    }

    private func startingBalanceCategory() -> Category? {
        let incomeCategories = categoryGroups.flatMap(\.categories).filter(\.isIncome)
        return incomeCategories.first { $0.name.lowercased() == "starting balances" }
            ?? incomeCategories.first
    }

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
            throw error
        } catch {
            throw BudgetStoreError.categoryGroupCreationFailed(error.localizedDescription)
        }

        await refreshDataOnly()
        return group
    }

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

    func renameCategory(id: String, name: String, month: String) async throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw BudgetStoreError.invalidCategoryName
        }
        guard let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }

        do {
            try await syncClient.renameCategory(id: id, name: trimmedName)
        } catch let error as BudgetDatabase.CategoryWriteError {
            throw error
        } catch {
            throw BudgetStoreError.categoryUpdateFailed(error.localizedDescription)
        }

        await refreshDataOnly()
        await fetchBudgetMonth(month)
    }

    func setCategoryHidden(id: String, hidden: Bool, month: String) async throws {
        guard let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }

        do {
            try await syncClient.setCategoryHidden(id: id, hidden: hidden)
        } catch {
            throw BudgetStoreError.categoryUpdateFailed(error.localizedDescription)
        }

        await refreshDataOnly()
        await fetchBudgetMonth(month)
    }

    func setCategoryGroupHidden(id: String, hidden: Bool, month: String) async throws {
        guard let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }

        do {
            try await syncClient.setCategoryGroupHidden(id: id, hidden: hidden)
        } catch {
            throw BudgetStoreError.categoryUpdateFailed(error.localizedDescription)
        }

        await refreshDataOnly()
        await fetchBudgetMonth(month)
    }

    func fetchAccountsMonthSummary(month: String) async -> BudgetDatabase.AccountsMonthSummary? {
        do {
            return try await database?.fetchAccountsMonthSummary(month: month)
        } catch is CancellationError {
            return nil
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    // MARK: - Transactions

    func fetchTransactions(
        accountId: String? = nil,
        limit: Int = BudgetDatabase.transactionPageSize,
        offset: Int = 0,
        search: String? = nil,
        unclearedOnly: Bool = false,
        hideReconciled: Bool = false
    ) async -> [Transaction] {
        do {
            return try await database?.fetchTransactions(
                accountId: accountId, limit: limit, offset: offset, search: search,
                unclearedOnly: unclearedOnly, hideReconciled: hideReconciled
            ) ?? []
        } catch is CancellationError {
            return []
        } catch {
            self.error = error.localizedDescription
            return []
        }
    }

    func fetchCategoryTransactions(categoryId: String, month: String? = nil) async -> [Transaction] {
        do {
            return try await database?.fetchCategoryTransactions(categoryId: categoryId, month: month) ?? []
        } catch {
            self.error = error.localizedDescription
            return []
        }
    }

    func fetchUncategorizedTransactions() async -> [Transaction] {
        do {
            return try await database?.fetchUncategorizedTransactions() ?? []
        } catch {
            self.error = error.localizedDescription
            return []
        }
    }

    func createTransaction(_ transaction: Transaction) async throws {
        guard let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }

        try await syncClient.createTransaction(transaction)
        await refreshDataOnly()
    }

    struct WalletImportResult: Equatable {
        var imported: Int
        var skippedDuplicates: Int
    }

    func importWalletTransactions(
        _ candidates: [WalletImportCandidate],
        accountId: String
    ) async throws -> WalletImportResult {
        guard let database, let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }
        var existing = try database.existingFinancialIds(accountId: accountId)
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
                sortOrder: nil,
                importedPayee: payeeName,
                financialId: candidate.id
            )
            try await syncClient.createTransaction(transaction, prepared: prepared)
            imported += 1
        }
        await refreshDataOnly()
        return WalletImportResult(imported: imported, skippedDuplicates: skipped)
    }

    func walletFinancialIds(accountId: String) -> Set<String> {
        (try? database?.existingFinancialIds(accountId: accountId)) ?? []
    }

    // MARK: - Bank Sync (SimpleFIN & Apple Wallet)

    private var simpleFINClient = SimpleFINClient()
    private var simpleFINAccessKeyProvider = { SimpleFINCredentials.accessKey }
    private var appleWalletStore: any AppleWalletReading = FinanceKitWalletStore()
    private var appleWalletLinkDefaults = UserDefaults.standard

    private func appleWalletLinksKey(for budgetId: String) -> String {
        "appleWalletLinks_\(budgetId)"
    }

    private func bankSyncImportStartKey(for budgetId: String) -> String {
        "bankSyncImportStart_\(budgetId)"
    }

    private var storedBankSyncImportStartDay: Int? {
        guard let budgetId = currentBudgetId else { return nil }
        return appleWalletLinkDefaults
            .object(forKey: bankSyncImportStartKey(for: budgetId)) as? Int
    }

    func setBankSyncImportStartDay(_ day: Int) {
        guard let budgetId = currentBudgetId else { return }
        appleWalletLinkDefaults.set(day, forKey: bankSyncImportStartKey(for: budgetId))
    }

    func resolvedBankSyncImportStartDay() async -> Int {
        if let chosen = storedBankSyncImportStartDay { return chosen }
        if let began = try? await database?.earliestMessageDay() { return began }
        return DayDate.today().adding(days: -Self.bankSyncMaxLookbackDays).yyyymmdd
    }

    private var appleWalletLinks: [String: String] {
        get {
            guard let budgetId = currentBudgetId else { return [:] }
            return appleWalletLinkDefaults.dictionary(
                forKey: appleWalletLinksKey(for: budgetId)
            ) as? [String: String] ?? [:]
        }
        set {
            guard let budgetId = currentBudgetId else { return }
            appleWalletLinkDefaults.set(newValue, forKey: appleWalletLinksKey(for: budgetId))
        }
    }

    private func forgetAppleWalletLinks(for budgetId: String) {
        appleWalletLinkDefaults.removeObject(forKey: appleWalletLinksKey(for: budgetId))
    }

    @Published private(set) var appleWalletAvailability: AppleWalletAvailability = .unsupported

    func refreshAppleWalletAvailability() async {
        appleWalletAvailability = await appleWalletStore.availability()
    }

    @discardableResult
    func connectAppleWallet() async throws -> Bool {
        let granted = try await appleWalletStore.requestAccess()
        appleWalletAvailability = await appleWalletStore.availability()
        return granted
    }

    func fetchAppleWalletAccounts() async throws -> [AppleWalletAccount] {
        try await appleWalletStore.accounts()
    }

    private static let bankSyncMaxLookbackDays = 89

    struct BankSyncResult: Equatable {
        var accountsSynced = 0
        var added = 0
        var updated = 0
        var importedTransactions: [Transaction] = []
        var problems: [String] = []

        var summary: String {
            var lines: [String] = []
            if added > 0 {
                lines.append("Imported \(added) new transaction\(added == 1 ? "" : "s").")
            }
            if updated > 0 {
                lines.append("Matched \(updated) transaction\(updated == 1 ? "" : "s") you already had.")
            }
            if lines.isEmpty, problems.isEmpty {
                lines.append(accountsSynced == 0
                    ? "No linked accounts to sync."
                    : "Everything is already up to date.")
            }
            return (lines + problems).joined(separator: "\n\n")
        }
    }

    @Published var bankSyncSummary: String?
    @Published private(set) var serverProvidesBankSync = false

    var canSyncBanks: Bool { serverProvidesBankSync || isSimpleFINConfigured }

    func refreshBankSyncSource() async {
        if let configured = try? await serverClient.simpleFINStatus() {
            serverProvidesBankSync = configured == true
        }
    }

    private func makeBankSyncProvider() async throws -> any BankSyncProvider {
        let deviceKey = simpleFINAccessKeyProvider()
        do {
            if try await serverClient.simpleFINStatus() == true {
                serverProvidesBankSync = true
                return ActualServerBankSyncProvider(client: serverClient)
            }
            serverProvidesBankSync = false
        } catch {
            guard let deviceKey else {
                if let serverError = error as? ActualServerError, serverError.isConnectionFailure {
                    throw error
                }
                throw BudgetStoreError.bankSyncNotConfigured
            }
            return SimpleFINDirectProvider(client: simpleFINClient, accessKey: deviceKey)
        }
        guard let deviceKey else { throw BudgetStoreError.bankSyncNotConfigured }
        return SimpleFINDirectProvider(client: simpleFINClient, accessKey: deviceKey)
    }

    func runBankSync(accountIds: [String] = []) async {
        guard !isBankSyncing else { return }
        do {
            bankSyncSummary = try await syncBankAccounts(accountIds: accountIds).summary
        } catch {
            bankSyncSummary = error.localizedDescription
        }
    }

    func connectSimpleFIN(setupToken: String) async throws {
        let accessKey = try await simpleFINClient.claimAccessKey(setupToken: setupToken)
        try SimpleFINCredentials.save(accessKey)
        isSimpleFINConfigured = true
    }

    func disconnectSimpleFIN() throws {
        try SimpleFINCredentials.clear()
        isSimpleFINConfigured = false
    }

    func fetchBankAccounts() async throws -> [SimpleFINAccount] {
        try await makeBankSyncProvider().accounts()
    }

    func loadBankSyncAccounts() async {
        guard let database else {
            bankSyncAccounts = []
            return
        }
        var synced = (try? await database.fetchBankSyncAccounts()) ?? []

        let strays = synced.filter { $0.source == .financeKit }
        if !strays.isEmpty, currentBudgetId != nil {
            var links = appleWalletLinks
            for stray in strays where links[stray.id] == nil {
                links[stray.id] = stray.externalAccountId
            }
            appleWalletLinks = links
            if let syncClient {
                for stray in strays {
                    try? await syncClient.unlinkAccount(accountId: stray.id)
                }
                synced = (try? await database.fetchBankSyncAccounts()) ?? []
            } else {
                synced.removeAll { $0.source == .financeKit }
            }
        }

        let walletLinks = appleWalletLinks
        guard !walletLinks.isEmpty else {
            bankSyncAccounts = synced
            return
        }
        let syncedById = Dictionary(uniqueKeysWithValues: synced.map { ($0.id, $0) })
        let budgetAccounts = (try? await database.fetchAccounts()) ?? accounts
        bankSyncAccounts = budgetAccounts.compactMap { account in
            if let linked = syncedById[account.id] { return linked }
            guard let externalId = walletLinks[account.id] else { return nil }
            return BankSyncAccount(
                id: account.id,
                name: account.name,
                externalAccountId: externalId,
                syncSource: BankSyncSource.financeKit.rawValue,
                offBudget: account.offBudget,
                closed: account.closed
            )
        }
    }

    func bankSyncAccount(forAccountId accountId: String) -> BankSyncAccount? {
        bankSyncAccounts.first { $0.id == accountId }
    }

    @discardableResult
    func autoSyncAppleWalletAccounts() async -> [Transaction] {
        let walletIds = bankSyncAccounts
            .filter { $0.source == .financeKit && !$0.closed }
            .map(\.id)
        guard !walletIds.isEmpty else { return [] }
        guard await appleWalletStore.availability() == .authorized else { return [] }
        guard let result = try? await syncBankAccounts(accountIds: walletIds),
              !result.importedTransactions.isEmpty else { return [] }

        return result.importedTransactions
    }

    func linkBankAccount(accountId: String, to remote: BankSyncRemoteAccount) async throws {
        if remote.source == .financeKit {
            guard currentBudgetId != nil else { throw BudgetStoreError.syncNotConfigured }
            var links = appleWalletLinks
            links[accountId] = remote.id
            appleWalletLinks = links
            await loadBankSyncAccounts()
            return
        }
        guard let syncClient else { throw BudgetStoreError.syncNotConfigured }
        try await syncClient.linkAccount(
            accountId: accountId,
            externalAccountId: remote.id,
            source: remote.source,
            institutionId: remote.institutionId,
            institutionName: remote.institutionName
        )
        var links = appleWalletLinks
        links.removeValue(forKey: accountId)
        appleWalletLinks = links
        await refreshDataOnly()
    }

    func unlinkBankAccount(accountId: String) async throws {
        if bankSyncAccount(forAccountId: accountId)?.source == .financeKit {
            var links = appleWalletLinks
            links.removeValue(forKey: accountId)
            appleWalletLinks = links
            await loadBankSyncAccounts()
            return
        }
        guard let syncClient else { throw BudgetStoreError.syncNotConfigured }
        try await syncClient.unlinkAccount(accountId: accountId)
        await refreshDataOnly()
    }

    @discardableResult
    func syncBankAccounts(accountIds: [String] = []) async throws -> BankSyncResult {
        guard let database, let syncClient else { throw BudgetStoreError.syncNotConfigured }
        guard !isBankSyncing else { return BankSyncResult() }

        let linked = bankSyncAccounts.filter {
            !$0.closed && (accountIds.isEmpty || accountIds.contains($0.id))
        }
        let simpleFinTargets = linked.filter { $0.source == .simpleFin }
        var walletTargets = linked.filter { $0.source == .financeKit }
        guard !(simpleFinTargets.isEmpty && walletTargets.isEmpty) else { return BankSyncResult() }

        isBankSyncing = true
        defer { isBankSyncing = false }

        var result = BankSyncResult()

        if !walletTargets.isEmpty {
            switch await appleWalletStore.availability() {
            case .authorized:
                break
            case .denied:
                result.problems.append(
                    "Wallet access is turned off. Allow Actuali to read Wallet in Settings, then sync again."
                )
                walletTargets = []
            case .unsupported, .notDetermined:
                walletTargets = []
            }
        }

        let targets = simpleFinTargets + walletTargets
        guard !targets.isEmpty else { return result }

        let importStart = await resolvedBankSyncImportStartDay()
        let lookbackFloor = DayDate.today()
            .adding(days: -Self.bankSyncMaxLookbackDays).yyyymmdd
        var oldestDates: [String: Int] = [:]
        for target in targets {
            oldestDates[target.id] = (try? await database.oldestTransactionDate(accountId: target.id)) ?? nil
        }
        func downloadTargets(_ accounts: [BankSyncAccount]) -> [BankSyncTarget] {
            accounts.map {
                guard let oldest = oldestDates[$0.id] else {
                    return BankSyncTarget(externalId: $0.externalAccountId, startDay: importStart)
                }
                let incremental = max(lookbackFloor, oldest)
                return BankSyncTarget(
                    externalId: $0.externalAccountId,
                    startDay: importStart < oldest ? importStart : incremental
                )
            }
        }

        var downloaded = BankSyncDownloadSet()
        var simpleFinProblems: [String] = []
        var walletProblems: [String] = []
        if !simpleFinTargets.isEmpty {
            do {
                let provider = try await makeBankSyncProvider()
                let set = try await provider.download(downloadTargets(simpleFinTargets))
                downloaded.byAccount.merge(set.byAccount) { first, _ in first }
                simpleFinProblems += set.problems
            } catch {
                guard !walletTargets.isEmpty else { throw error }
                simpleFinProblems.append(error.localizedDescription)
            }
        }
        if !walletTargets.isEmpty {
            do {
                let set = try await AppleWalletProvider(store: appleWalletStore)
                    .download(downloadTargets(walletTargets))
                downloaded.byAccount.merge(set.byAccount) { first, _ in first }
                walletProblems += set.problems
            } catch {
                guard !simpleFinTargets.isEmpty else { throw error }
                walletProblems.append(error.localizedDescription)
            }
        }

        result.problems += simpleFinProblems + walletProblems
        let prepared = await syncClient.prepareRules()
        let syncedAt = String(Int64(Date().timeIntervalSince1970 * 1000))
        var statuses: [(accountId: String, lastSync: String?, status: String)] = []

        for target in targets {
            guard let download = downloaded.byAccount[target.externalAccountId] else {
                let sourceHasProblems = target.source == .financeKit
                    ? !walletProblems.isEmpty
                    : !simpleFinProblems.isEmpty
                if target.source == .simpleFin && !sourceHasProblems {
                    result.problems.append(
                        "\(target.name): SimpleFIN didn't return this account. Unlink it and link it again."
                    )
                }
                if target.source != .financeKit {
                    statuses.append((target.id, nil,
                                     sourceHasProblems ? "failed" : "account-missing"))
                }
                continue
            }
            if let problem = download.problem {
                result.problems.append("\(target.name): \(problem)")
            }
            do {
                let outcome = try await importBankSync(
                    download,
                    into: target,
                    existingOldestDay: oldestDates[target.id],
                    prepared: prepared
                )
                result.added += outcome.added
                result.updated += outcome.updated
                result.importedTransactions += outcome.inserted
                result.accountsSynced += 1
                statuses.append((target.id, syncedAt, download.status))
            } catch {
                result.problems.append("\(target.name): \(error.localizedDescription)")
                statuses.append((target.id, nil, "failed"))
            }
        }

        try? await syncClient.recordBankSyncStatus(statuses)

        await refreshDataOnly()
        return result
    }

    private func importBankSync(
        _ download: BankSyncDownload,
        into target: BankSyncAccount,
        existingOldestDay: Int?,
        prepared: SyncClient.PreparedRules
    ) async throws -> (added: Int, updated: Int, inserted: [Transaction]) {
        guard let database, let syncClient else { throw BudgetStoreError.syncNotConfigured }

        var candidates = download.candidates
        var added = 0
        if existingOldestDay == nil {
            added += try await insertStartingBalance(
                for: target,
                currentBalanceCents: download.currentBalanceCents,
                candidates: candidates
            ) ? 1 : 0
        }
        guard let earliest = candidates.map(\.date).min(),
              let latest = candidates.map(\.date).max() else { return (added, 0, []) }

        let payeeIdsByName = Dictionary(
            (try? await database.fetchPayees())?.map { ($0.name.lowercased(), $0.id) } ?? [],
            uniquingKeysWith: { first, _ in first }
        )
        for index in candidates.indices {
            candidates[index].payeeId = payeeIdsByName[candidates[index].payeeName.lowercased()]
        }

        let radius = BankSyncReconciler.fuzzyMatchDayRadius
        let window = try await database.bankSyncWindow(
            accountId: target.id,
            from: DayDate(yyyymmdd: earliest)?.adding(days: -radius).yyyymmdd ?? earliest,
            to: DayDate(yyyymmdd: latest)?.adding(days: radius).yyyymmdd ?? latest
        )

        let plan = BankSyncReconciler.plan(candidates: candidates, existing: window)
        try await syncClient.applyBankSyncUpdates(plan.updates)

        var inserted: [Transaction] = []
        for candidate in plan.inserts.sorted(by: { $0.date < $1.date }) {
            let payeeId = try await resolvePayeeId(name: candidate.payeeName, editing: nil)
            let transaction = Transaction(
                id: UUID().uuidString,
                accountId: target.id,
                date: candidate.date,
                amount: candidate.amount,
                payeeId: payeeId,
                payeeName: candidate.payeeName,
                categoryId: nil,
                categoryName: nil,
                notes: candidate.notes,
                cleared: candidate.cleared,
                reconciled: false,
                transferId: nil,
                isParent: false,
                parentId: nil,
                tombstone: false,
                sortOrder: nil,
                importedPayee: candidate.payeeName,
                financialId: candidate.importedId
            )
            try await syncClient.createTransaction(transaction, prepared: prepared)
            inserted.append(transaction)
        }

        if let existingOldestDay {
            try await absorbIntoStartingBalance(
                for: target,
                backfilled: inserted.filter { $0.date < existingOldestDay }
            )
        }

        return (added + plan.inserts.count, plan.updates.count, inserted)
    }

    private func absorbIntoStartingBalance(
        for target: BankSyncAccount, backfilled: [Transaction]
    ) async throws {
        guard let database, let syncClient else { return }
        let carried = backfilled.reduce(0) { $0 + $1.amount }
        guard carried != 0 else { return }
        guard let openingId = try await database.startingBalanceTransactionId(
            accountId: target.id
        ), var opening = try await database.fetchTransaction(id: openingId) else { return }

        opening.amount -= carried
        try await syncClient.updateTransaction(opening, changedFields: ["amount"])
    }

    @discardableResult
    private func insertStartingBalance(
        for target: BankSyncAccount,
        currentBalanceCents: Int?,
        candidates: [BankSyncCandidate]
    ) async throws -> Bool {
        guard let syncClient, let balance = currentBalanceCents else { return false }
        let opening = balance - candidates.reduce(0) { $0 + $1.amount }
        guard opening != 0 else { return false }

        let payee = try await findOrCreatePayee(name: "Starting Balance")
        let category = target.offBudget ? nil : startingBalanceCategory()

        let transaction = Transaction(
            id: UUID().uuidString,
            accountId: target.id,
            date: candidates.map(\.date).min() ?? Transaction.yyyymmdd(from: Date()),
            amount: opening,
            payeeId: payee.id,
            payeeName: payee.name,
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
        try await syncClient.createTransaction(transaction, applyRules: false)
        return true
    }

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

    var offBudgetAccountIds: Set<String> {
        Set(accounts.filter(\.offBudget).map(\.id))
    }

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
        func resolvedCategory(for leg: Transaction, accountId: String,
                              otherAccountId: String) -> String? {
            guard !offBudgetIds.contains(accountId),
                  offBudgetIds.contains(otherAccountId) else { return nil }
            return leg.id == original.id ? categoryId : leg.categoryId
        }

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

    func updateTransaction(_ updated: Transaction, original: Transaction) async throws {
        guard let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }

        let changedFields = Self.changedFields(original: original, updated: updated)
        try await syncClient.updateTransaction(updated, changedFields: changedFields)
        await refreshDataOnly()
    }

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

    func fetchSplitChildren(parentId: String) async -> [Transaction] {
        guard let database else { return [] }
        return (try? await database.fetchChildTransactions(parentId: parentId)) ?? []
    }

    func deleteTransaction(_ transaction: Transaction) async {
        await deleteTransactions([transaction])
    }

    func deleteTransactions(_ transactions: [Transaction]) async {
        guard let syncClient else {
            self.error = BudgetStoreError.syncNotConfigured.localizedDescription
            return
        }
        var deleted: [Transaction] = []
        for tx in transactions {
            if tx.isParent, let database {
                do {
                    for child in try await database.fetchChildTransactions(parentId: tx.id) {
                        var deletedChild = child
                        deletedChild.tombstone = true
                        deleted.append(deletedChild)
                    }
                } catch {
                    self.error = "Failed to delete transaction: \(error.localizedDescription)"
                    continue
                }
            }
            var copy = tx
            copy.tombstone = true
            deleted.append(copy)
        }
        do {
            try await syncClient.updateTransactions(deleted, changedFields: ["tombstone"])
        } catch {
            self.error = "Failed to delete transaction: \(error.localizedDescription)"
        }
        await refreshDataOnly()
    }

    func duplicateTransaction(_ transaction: Transaction) async {
        await duplicateTransactions([transaction])
    }

    func duplicateTransactions(_ transactions: [Transaction]) async {
        guard syncClient != nil else {
            self.error = BudgetStoreError.syncNotConfigured.localizedDescription
            return
        }
        let baseSortOrder = Date().timeIntervalSince1970 * 1000
        var handledTransferIds = Set<String>()
        for (index, tx) in transactions.enumerated() {
            if handledTransferIds.contains(tx.id) {
                continue
            }
            if let transferId = tx.transferId, !transferId.isEmpty {
                handledTransferIds.insert(transferId)
            }
            do {
                try await duplicateSingleTransaction(tx, sortOrder: baseSortOrder + Double(index))
            } catch {
                self.error = "Failed to duplicate transaction: \(error.localizedDescription)"
            }
        }
        await refreshDataOnly()
    }

    private func makeDuplicateTransaction(
        from source: Transaction,
        id: String = UUID().uuidString,
        sortOrder: Double
    ) -> Transaction {
        Transaction(
            id: id,
            accountId: source.accountId,
            date: source.date,
            amount: source.amount,
            payeeId: source.payeeId,
            payeeName: source.payeeName,
            categoryId: source.categoryId,
            categoryName: source.categoryName,
            notes: source.notes,
            cleared: false,
            reconciled: false,
            transferId: nil,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: sortOrder,
            importedPayee: source.importedPayee,
            schedule: nil
        )
    }

    private func duplicateSingleTransaction(
        _ transaction: Transaction,
        sortOrder: Double
    ) async throws {
        guard let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }

        if let transferId = transaction.transferId, !transferId.isEmpty, let database {
            if let partner = try await database.fetchTransaction(id: transferId) {
                let newSourceId = UUID().uuidString
                let newTargetId = UUID().uuidString

                var newSource = makeDuplicateTransaction(from: transaction, id: newSourceId, sortOrder: sortOrder)
                newSource.transferId = newTargetId

                var newTarget = makeDuplicateTransaction(from: partner, id: newTargetId, sortOrder: sortOrder)
                newTarget.transferId = newSourceId

                try await syncClient.createTransfer(source: newSource, target: newTarget)
                return
            }
        }

        if transaction.isParent, let database {
            let newParentId = UUID().uuidString
            let children = try await database.fetchChildTransactions(parentId: transaction.id)
            let newChildren = children.enumerated().map { index, child in
                var newChild = makeDuplicateTransaction(from: child, sortOrder: sortOrder - Double(index + 1) * 0.001)
                newChild.parentId = newParentId
                if child.transferAcct != nil {
                    newChild.payeeId = nil
                    newChild.payeeName = nil
                }
                return newChild
            }
            var newParent = makeDuplicateTransaction(from: transaction, id: newParentId, sortOrder: sortOrder)
            newParent.isParent = true
            try await syncClient.createSplit(parent: newParent, children: newChildren)
            return
        }

        var newTx = makeDuplicateTransaction(from: transaction, sortOrder: sortOrder)
        if transaction.transferAcct != nil {
            newTx.payeeId = nil
            newTx.payeeName = nil
        }
        try await syncClient.createTransaction(newTx, applyRules: false)
    }

    func setClearedStatus(transactions: [Transaction], cleared: Bool) async {
        guard let syncClient else {
            self.error = BudgetStoreError.syncNotConfigured.localizedDescription
            return
        }
        var updated: [Transaction] = []
        for tx in transactions where !tx.reconciled && tx.cleared != cleared {
            var copy = tx
            copy.cleared = cleared
            guard tx.isParent, let database else {
                updated.append(copy)
                continue
            }
            do {
                var batch = [copy]
                for child in try await database.fetchChildTransactions(parentId: tx.id)
                where !child.reconciled && child.cleared != cleared {
                    var childCopy = child
                    childCopy.cleared = cleared
                    batch.append(childCopy)
                }
                updated.append(contentsOf: batch)
            } catch {
                self.error = "Failed to update cleared status: \(error.localizedDescription)"
            }
        }
        let locked = transactions.filter { $0.reconciled && $0.cleared != cleared }.count
        if locked > 0 {
            self.error = "\(locked) reconciled transaction\(locked == 1 ? "" : "s") stayed locked. Unlock from the status dot to change them."
        }
        guard !updated.isEmpty else { return }
        do {
            try await syncClient.updateTransactions(updated, changedFields: ["cleared"])
        } catch {
            self.error = "Failed to update cleared status: \(error.localizedDescription)"
        }
        await refreshDataOnly()
    }

    // MARK: - Reconciliation

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

    func clearedBalance(accountId: String) async -> Int? {
        guard let database else { return nil }
        do {
            return try await database.clearedBalance(accountId: accountId)
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func balanceBreakdown(accountId: String) async -> AccountBalanceBreakdown? {
        guard let database else { return nil }
        return try? await database.balanceBreakdown(accountId: accountId)
    }

    func fetchCycleSpend(accountId: String, start: DayDate, end: DayDate) async -> Int {
        guard let database else { return 0 }
        return (try? await database.fetchAccountSpend(
            accountId: accountId,
            fromDate: start.yyyymmdd,
            toDate: end.yyyymmdd
        )) ?? 0
    }

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
        var collapseSplit: Bool = false
        var recordLocation: Bool = true
    }

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

    struct SplitPlanLine: Equatable {
        var categoryId: String?
        var amountCents: Int
        var notes: String?
        var payeeName: String? = nil
        var childId: String? = nil
    }

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

    @discardableResult
    func saveTransaction(_ form: TransactionForm, editing original: Transaction? = nil) async throws -> String? {
        var form = form
        if original == nil, form.type != .transfer,
           offBudgetAccountIds.contains(form.accountId) {
            form.categoryId = nil
            form.splits = []
        }
        let date = Transaction.yyyymmdd(from: form.date)
        let notes = form.notes.isEmpty ? nil : form.notes

        switch try Self.plan(for: form) {
        case .transfer(let toAccountId, let amountCents):
            if let original {
                guard original.transferId != nil else {
                    try await convertToTransfer(
                        original: original, form: form, otherAccountId: toAccountId,
                        amountCents: amountCents, date: date, notes: notes
                    )
                    return nil
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
                return nil
            }
            try await createTransfer(
                fromAccountId: form.accountId,
                toAccountId: toAccountId,
                amountCents: amountCents,
                date: date,
                notes: notes,
                cleared: form.cleared
            )
            return nil

        case .split(let amountCents, let lines):
            if let original {
                if original.isParent {
                    try await updateSplit(
                        original: original, form: form,
                        amountCents: amountCents, lines: lines,
                        date: date, notes: notes
                    )
                    return nil
                }
                try await convertToSplit(
                    original: original, form: form,
                    amountCents: amountCents, lines: lines,
                    date: date, notes: notes
                )
                return nil
            }
            let payeeId = try await resolvePayeeId(name: form.payeeName, editing: nil)
            let payeeName = form.payeeName.isEmpty ? nil : form.payeeName
            let parentId = UUID().uuidString
            let parentSort = Date().timeIntervalSince1970 * 1000
            let parent = Transaction(
                id: parentId,
                accountId: form.accountId,
                date: date,
                amount: amountCents,
                payeeId: payeeId,
                payeeName: payeeName,
                categoryId: nil,
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
            return nil

        case .standard(let amountCents):
            let payeeId = try await resolvePayeeId(name: form.payeeName, editing: original)
            let payeeName = form.payeeName.isEmpty ? nil : form.payeeName

            if let original {
                if original.isParent, form.collapseSplit {
                    try await collapseSplit(
                        original: original, form: form,
                        amountCents: amountCents, date: date, notes: notes
                    )
                    return nil
                }
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
                return nil
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
                    sortOrder: nil,
                    importedPayee: payeeName
                )
                try await createTransaction(transaction)
                if form.recordLocation, let payeeId {
                    recordPayeeLocationIfAppropriate(payeeId: payeeId)
                }
                return transaction.id
            }
        }
    }

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
            categoryId: nil,
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

        var nextNewSort = (existingChildren.compactMap(\.sortOrder).min()
            ?? original.sortOrder
            ?? Date().timeIntervalSince1970 * 1000)

        for line in lines {
            let existing = line.childId.flatMap { childrenById[$0] }
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
            cleared: false,
            reconciled: false,
            transferId: original.id,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: nil,
            importedPayee: nil
        )

        try await syncClient.convertToTransfer(
            leg: leg,
            changedFields: Self.changedFields(original: original, updated: leg),
            partner: partner
        )
        await refreshDataOnly()
    }

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
            categoryId: nil,
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

    func resolvePayeeId(name: String, editing original: Transaction?) async throws -> String? {
        if name.isEmpty { return nil }
        if name == original?.payeeName { return original?.payeeId }
        do {
            return try await findOrCreatePayee(name: name).id
        } catch {
            throw BudgetStoreError.payeeCreationFailed(error.localizedDescription)
        }
    }

    static func shouldRecordLocation(at position: Coordinates, existing: [PayeeLocation]) -> Bool {
        !existing.contains { location in
            LocationUtils.calculateDistanceMeters(
                lat1: position.latitude, lon1: position.longitude,
                lat2: location.latitude, lon2: location.longitude
            ) <= LocationUtils.defaultMaxDistanceMeters
        }
    }

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

    func sync() async {
        let work = Task {
            logger.info("sync() called")
            if syncClient == nil {
                logger.notice("syncClient is nil, cannot sync!")
            }
            await syncClient?.syncNow()
            lastSyncTime = Date()
            logger.debug("sync() completed, refreshing data...")
            await refreshDataOnly()
            let walletTransactions = await autoSyncAppleWalletAccounts()
            await notifyAboutSyncedTransactions(additional: walletTransactions)
        }
        await work.value
    }

    func resetSyncState() async {
        logger.notice("resetSyncState() called from BudgetStore")
        await syncClient?.resetSyncState()
        lastSyncTime = Date()
        await refreshDataOnly()
    }

    func flushPendingSync() async {
        await syncClient?.flushPendingSync()
    }

    func hasPendingLocalWrites() async -> Bool {
        await syncClient?.hasPendingLocalWrites() ?? false
    }

    func syncOnForeground() async {
        Task { await serverClient.retryPrimaryIfRecovered() }
        guard let client = syncClient else {
            logger.debug("syncOnForeground() skipped - no budget loaded")
            return
        }
        logger.info("syncOnForeground() - app became active, syncing...")
        let success = await client.automaticSync()
        lastSyncTime = Date()
        if success { await postDueSchedulesIfNeeded() }
        await refreshDataOnly()
        let walletTransactions = await autoSyncAppleWalletAccounts()
        await notifyAboutSyncedTransactions(additional: walletTransactions)
    }

    func syncInBackground() async -> Bool {
        await ensureBudgetReady()
        guard let client = syncClient else {
            logger.debug("syncInBackground() skipped - no budget configured")
            return false
        }
        await client.automaticSync()
        lastSyncTime = Date()
        await refreshDataOnly()
        let walletTransactions = await autoSyncAppleWalletAccounts()
        await notifyAboutSyncedTransactions(additional: walletTransactions)
        return true
    }

    func transaction(withId id: String) async -> Transaction? {
        if let cached = transactions.first(where: { $0.id == id }) { return cached }
        guard let database else { return nil }
        return (try? await database.fetchTransaction(id: id)) ?? nil
    }

    func notifyAboutSyncedTransactions(additional: [Transaction] = []) async {
        await notifyAboutTransactions(await detectNewTransactionsForNotification() + additional)
    }

    private func notifyAboutTransactions(_ fresh: [Transaction]) async {
        let accountNames = accounts.reduce(into: [String: String]()) {
            $0[$1.id] = $1.name
        }
        await NewTransactionNotifier.notify(
            about: fresh,
            currencyCode: currencyCode,
            narrowSymbol: useNarrowCurrencySymbol,
            numberFormat: numberFormat,
            accountNames: accountNames,
            offBudgetAccountIds: offBudgetAccountIds
        )
    }

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

    private var schedulePoster: SchedulePoster?
    private var scheduleNoticeDismissTask: Task<Void, Never>?

    static func schedulePostNoticeText(count: Int) -> String {
        "Posted \(count) scheduled transaction\(count == 1 ? "" : "s")"
    }

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

    private func postDueSchedulesAfterSync() async {
        if await postDueSchedulesIfNeeded() > 0 {
            await refreshDataOnly()
        }
    }

    @discardableResult
    private func postDueSchedulesIfNeeded() async -> Int {
        guard let client = syncClient,
              let database,
              let budgetId = currentBudgetId else { return 0 }
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

    @discardableResult
    func createSchedules(_ fields: [ScheduleFormFields]) async throws -> [String] {
        guard let syncClient else { throw BudgetStoreError.syncNotConfigured }

        var ids: [String] = []
        do {
            for field in fields {
                ids.append(try await syncClient.createSchedule(fields: field))
            }
        } catch {
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
    
    func discoverSchedules() async -> [ScheduleDiscovery.Proposal] {
        guard let database else { return [] }
        return await Self.runDiscovery(accounts: accounts, database: database)
    }

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

    private var requestedBudgetMonth: String?
    private var budgetMonthRequestGeneration = 0

    func fetchBudgetMonth(_ month: String) async {
        budgetMonthRequestGeneration += 1
        requestedBudgetMonth = month
        do {
            let fetched = try await database?.fetchBudgetMonth(month: month)
            guard requestedBudgetMonth == month else { return }
            currentBudgetMonth = fetched
        } catch is CancellationError {
        } catch {
            guard requestedBudgetMonth == month else { return }
            self.error = error.localizedDescription
        }
    }

    // MARK: - Budget Amounts

    func budgetHistory(for category: CategoryBudget, monthCount: Int = 3) async -> [CategoryBudget] {
        guard let database, monthCount > 0 else { return [] }
        var result: [CategoryBudget] = []
        var month = category.month
        for _ in 0..<monthCount {
            guard let previous = Self.shiftBudgetMonth(month, by: -1) else { break }
            month = previous
            guard let budget = try? await database.fetchBudgetMonth(month: previous),
                  let priorCategory = budget.allCategoryBudgets.first(where: {
                      $0.categoryId == category.categoryId
                  }) else { continue }
            result.append(priorCategory)
        }
        return result
    }

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

    static func budgetAmountCents(from string: String, allowNegative: Bool = false) throws -> Int {
        guard let dollars = Double(string),
              let cents = Transaction.cents(fromDollars: dollars),
              allowNegative || cents >= 0 else {
            throw BudgetStoreError.invalidAmount
        }
        return cents
    }

    func setBudgetAmount(month: String, categoryId: String, amountCents: Int) async throws {
        guard let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }
        try await syncClient.setBudgetAmount(month: month, categoryId: categoryId, amount: amountCents)
        await fetchBudgetMonth(month)
    }

    func setBudgetCarryover(month: String, categoryId: String, enabled: Bool, now: Date = Date()) async throws {
        guard let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }
        try await syncClient.setBudgetCarryover(
            months: Self.carryoverMonths(from: month, now: now), categoryId: categoryId, flag: enabled)
        await fetchBudgetMonth(month)
    }

    nonisolated static func carryoverMonths(from month: String, now: Date = Date()) -> [String] {
        let latest = BudgetMonthMath.addMonths(BudgetMonthMath.currentMonth(now), 12)
        let count = max(BudgetMonthMath.differenceInCalendarMonths(latest, month), 0)
        return (0...count).map { BudgetMonthMath.addMonths(month, $0) }
    }

    func transferBudget(month: String, fromCategoryId: String?, toCategoryId: String?, amountCents: Int) async throws {
        guard let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }
        guard amountCents > 0 else {
            throw BudgetStoreError.transferAmountNotPositive
        }
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

    // MARK: - Goal Templates (budget goals, GH #371)

    @Published private(set) var goalTemplatesEnabled = false

    enum GoalTemplateAction {
        case check
        case apply
        case overwrite
    }

    enum GoalTemplateOutcome: Equatable {
        case applied(Int)
        case upToDate
        case checkPassed
        case errors([String])
        case failed(String)
    }

    func setGoalTemplatesEnabled(_ enabled: Bool) async {
        guard let syncClient else { return }
        do {
            try await syncClient.setPreference(
                id: "flags.goalTemplatesEnabled", value: enabled ? "true" : "false")
            goalTemplatesEnabled = enabled
        } catch {
            self.error = "Failed to update goal templates setting: \(error.localizedDescription)"
        }
    }

    func runGoalTemplates(
        month: String,
        action: GoalTemplateAction,
        categoryId: String? = nil
    ) async -> GoalTemplateOutcome {
        guard let database, let syncClient else {
            return .failed(BudgetStoreError.syncNotConfigured.localizedDescription)
        }
        do {
            let rows = try await database.fetchGoalTemplateCategories()
            let schedules = try await database.fetchSchedules()
                .filter { $0.name?.isEmpty == false }
                .map {
                    GoalScheduleInfo(
                        id: $0.id, name: $0.name, completed: $0.completed,
                        amount: $0.amount, dateCondition: $0.dateCondition)
                }

            var parsedNotes: [String: [GoalTemplate]] = [:]
            for row in rows where !row.sourceIsUI {
                if let note = row.note, GoalTemplateNotes.noteHasTemplates(note) {
                    let templates = GoalTemplateNotes.parseTemplates(fromNote: note)
                    if !templates.isEmpty { parsedNotes[row.id] = templates }
                }
            }

            if action == .check {
                return checkOutcome(rows: rows, parsedNotes: parsedNotes, schedules: schedules)
            }

            let scope: (String) -> Bool
            if let categoryId {
                scope = { $0 == categoryId }
            } else {
                scope = { _ in true }
            }

            var storeUpdates: [(categoryId: String, goalDef: String?, source: String)] = []
            for row in rows where scope(row.id) {
                guard let templates = parsedNotes[row.id] else { continue }
                let stored = row.goalDef.flatMap(GoalTemplate.decodeArray(fromJSON:))
                if stored != templates, let encoded = GoalTemplate.encodeArray(templates) {
                    storeUpdates.append((row.id, encoded, "notes"))
                }
            }
            try await syncClient.storeGoalDefs(storeUpdates)

            let resetIds = rows.filter {
                scope($0.id) && !$0.sourceIsUI && $0.goalDef != nil && parsedNotes[$0.id] == nil
            }.map(\.id)
            try await database.resetGoalDefs(categoryIds: resetIds)

            var categoryTemplates: [String: [GoalTemplate]] = parsedNotes
            for row in rows where row.sourceIsUI {
                if let stored = row.goalDef.flatMap(GoalTemplate.decodeArray(fromJSON:)),
                   !stored.isEmpty {
                    categoryTemplates[row.id] = stored
                }
            }
            if let categoryId {
                categoryTemplates = categoryTemplates.filter { $0.key == categoryId }
            }

            let sheet = try await database.fetchGoalTemplateSheet(month: month)
            let allCategories = rows.map {
                GoalTemplateCategory(id: $0.id, name: $0.name, isIncome: $0.isIncome)
            }
            let processCategories: [GoalTemplateCategory]
            if let categoryId {
                processCategories = rows
                    .filter { $0.id == categoryId }
                    .map { GoalTemplateCategory(id: $0.id, name: $0.name, isIncome: $0.isIncome) }
            } else {
                processCategories = rows
                    .filter { !$0.hidden && !$0.groupHidden && (sheet.isTracking || !$0.isIncome) }
                    .map { GoalTemplateCategory(id: $0.id, name: $0.name, isIncome: $0.isIncome) }
            }

            let result = GoalTemplateEngine.run(
                month: month,
                force: action == .overwrite || categoryId != nil,
                categoryTemplates: categoryTemplates,
                categories: processCategories,
                allCategories: allCategories,
                schedules: schedules,
                sheet: sheet)

            switch result {
            case .errors(let errors):
                return .errors(errors)
            case .upToDate(let goalResets):
                try await syncClient.applyGoalTemplateWrites(
                    month: month, budgets: [], goals: goalResets)
                if !goalResets.isEmpty { await fetchBudgetMonth(month) }
                return .upToDate
            case .applied(let count, let budgets, let goals):
                try await syncClient.applyGoalTemplateWrites(
                    month: month, budgets: budgets, goals: goals)
                await fetchBudgetMonth(month)
                return .applied(count)
            }
        } catch {
            logger.error("Goal template run failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Automation editor (goalTemplatesUIEnabled beta)

    @Published private(set) var goalTemplatesUIEnabled = false

    func setGoalTemplatesUIEnabled(_ enabled: Bool) async {
        guard let syncClient else { return }
        do {
            try await syncClient.setPreference(
                id: "flags.goalTemplatesUIEnabled", value: enabled ? "true" : "false")
            goalTemplatesUIEnabled = enabled
        } catch {
            self.error = "Failed to update automations setting: \(error.localizedDescription)"
        }
    }

    struct AutomationEditorData {
        var categoryName = ""
        var entries: [AutomationEntry] = []
        var cleanup = CleanupConfig()
        var needsMigration = false
        var originalNoteLines = ""
        var hasUnsupportedTemplates = false
        var existingNote = ""
        var schedules: [GoalScheduleInfo] = []
        var incomeSources: [(id: String, name: String)] = []
        var categoryNames: [String: String] = [:]
        var cleanupGroups: [(id: String, name: String)] = []
        var category = GoalTemplateCategory(id: "", name: "", isIncome: false)
        var allCategories: [GoalTemplateCategory] = []
        var sheet = GoalTemplateSheet()
    }

    func loadAutomationEditor(categoryId: String, month: String) async throws -> AutomationEditorData {
        guard let database else { throw BudgetStoreError.syncNotConfigured }
        let rows = try await database.fetchGoalTemplateCategories()
        guard let row = rows.first(where: { $0.id == categoryId }) else {
            throw BudgetStoreError.syncNotConfigured
        }

        var data = AutomationEditorData()
        data.categoryName = row.name
        data.needsMigration = !row.sourceIsUI
        data.existingNote = row.note ?? ""
        data.schedules = try await database.fetchSchedules()
            .filter { $0.name?.isEmpty == false }
            .map {
                GoalScheduleInfo(
                    id: $0.id, name: $0.name, completed: $0.completed,
                    amount: $0.amount, dateCondition: $0.dateCondition)
            }
        data.categoryNames = Dictionary(
            uniqueKeysWithValues: rows.map { ($0.id, $0.name) })
        data.incomeSources = rows.filter(\.isIncome).map { ($0.id, $0.name) }
        data.cleanupGroups = try await database.fetchCleanupGroups()
        data.category = GoalTemplateCategory(id: row.id, name: row.name, isIncome: row.isIncome)
        data.allCategories = rows.map {
            GoalTemplateCategory(id: $0.id, name: $0.name, isIncome: $0.isIncome)
        }
        data.sheet = try await database.fetchGoalTemplateSheet(month: month)

        var templates: [GoalTemplate]
        var cleanup: [CleanupTemplate]
        if data.needsMigration {
            templates = (row.note).map(GoalTemplateNotes.parseTemplates(fromNote:)) ?? []
            let parsedRows = (row.note).map(CleanupNotes.parseRows(fromNote:)) ?? []
            let neededNames = Set(parsedRows.compactMap(\.groupName))
            var nameToId = Dictionary(
                data.cleanupGroups.map { ($0.name.lowercased(), $0.id) },
                uniquingKeysWith: { first, _ in first })
            for name in neededNames where nameToId[name.lowercased()] == nil {
                let id = try await resolveCleanupGroup(name: name)
                nameToId[name.lowercased()] = id
                data.cleanupGroups.append((id, name))
            }
            cleanup = CleanupNotes.toTemplates(parsedRows) { nameToId[$0.lowercased()] }
            data.originalNoteLines = (row.note ?? "")
                .components(separatedBy: "\n")
                .filter {
                    let trimmed = $0.trimmingCharacters(in: .whitespaces)
                    return trimmed.hasPrefix("#template") || trimmed.hasPrefix("#goal")
                        || trimmed.lowercased().hasPrefix("#cleanup")
                }
                .joined(separator: "\n")
        } else {
            templates = row.goalDef.flatMap(GoalTemplate.decodeArray(fromJSON:)) ?? []
            cleanup = row.cleanupDef.flatMap(CleanupTemplate.decodeArray(fromJSON:)) ?? []
        }

        data.hasUnsupportedTemplates = templates.contains { $0.type == .error }
        let incomeNameToId = Dictionary(
            data.incomeSources.map { ($0.name.lowercased(), $0.id) },
            uniquingKeysWith: { first, _ in first })
        templates = templates.map { template in
            guard template.type == .percentage, let source = template.category,
                  let id = incomeNameToId[source.lowercased()] else { return template }
            var resolved = template
            resolved.category = id
            return resolved
        }

        if !data.hasUnsupportedTemplates {
            data.entries = BudgetAutomations.migrateToEntries(templates, schedules: data.schedules)
        }
        data.cleanup = CleanupConfig.from(cleanup: cleanup)
        return data
    }

    func dryRunAutomations(
        month: String,
        data: AutomationEditorData,
        templates: [GoalTemplate]
    ) -> (budgeted: Int, perTemplate: [Int]) {
        GoalTemplateEngine.dryRun(
            month: month,
            category: data.category,
            templates: templates,
            allCategories: data.allCategories,
            schedules: data.schedules,
            sheet: data.sheet)
    }

    func saveAutomations(
        categoryId: String,
        templates: [GoalTemplate],
        cleanup: [CleanupTemplate],
        cleanupGroups: [(id: String, name: String)]
    ) async throws {
        guard let database, let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }
        try await persistCleanupGroups(cleanup, named: cleanupGroups)
        try await syncClient.storeCategoryAutomations(
            categoryId: categoryId,
            goalDef: templates.isEmpty ? nil : GoalTemplate.encodeArray(templates),
            cleanupDef: cleanup.isEmpty ? nil : CleanupTemplate.encodeArray(cleanup),
            source: "ui")
        try await database.tombstoneOrphanCleanupGroups()
    }

    func resolveCleanupGroup(name: String) async throws -> String {
        guard let database else { throw BudgetStoreError.syncNotConfigured }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let id = try await database.findCleanupGroupId(named: trimmed) {
            return id
        }
        return UUID().uuidString.lowercased()
    }

    private func persistCleanupGroups(
        _ cleanup: [CleanupTemplate],
        named groups: [(id: String, name: String)]
    ) async throws {
        guard let database, let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }
        let referenced = Set(cleanup.compactMap(\.groupId))
        let live = Set(try await database.fetchCleanupGroups().map(\.id))
        for group in groups where referenced.contains(group.id) && !live.contains(group.id) {
            try await syncClient.upsertCleanupGroup(id: group.id, name: group.name)
        }
    }

    func renderUnmigrateNote(
        data: AutomationEditorData,
        templates: [GoalTemplate],
        cleanup: [CleanupTemplate]
    ) -> String {
        let categoryName: (String) -> String? = { data.categoryNames[$0] }
        let groupName: (String) -> String? = { id in
            data.cleanupGroups.first { $0.id == id }?.name
        }
        let rendered = [
            AutomationSentences.renderNoteTemplates(templates, categoryName: categoryName),
            CleanupNotes.toNotes(cleanup, groupName: groupName),
        ].filter { !$0.isEmpty }.joined(separator: "\n")
        return AutomationSentences.mergeIntoNote(
            existingNote: data.existingNote, rendered: rendered)
    }

    func unmigrateAutomations(categoryId: String, note: String) async throws {
        guard let syncClient else { throw BudgetStoreError.syncNotConfigured }
        try await syncClient.setNote(id: categoryId, note: note)

        let templates = GoalTemplateNotes.noteHasTemplates(note)
            ? GoalTemplateNotes.parseTemplates(fromNote: note) : []
        let cleanupRows = CleanupNotes.parseRows(fromNote: note)
        var cleanup: [CleanupTemplate] = []
        var cleanupGroups: [(id: String, name: String)] = []
        if !cleanupRows.isEmpty {
            let neededNames = Set(cleanupRows.compactMap(\.groupName))
            var nameToId: [String: String] = [:]
            if let database {
                for group in try await database.fetchCleanupGroups() {
                    nameToId[group.name.lowercased()] = group.id
                    cleanupGroups.append(group)
                }
            }
            for name in neededNames where nameToId[name.lowercased()] == nil {
                let id = try await resolveCleanupGroup(name: name)
                nameToId[name.lowercased()] = id
                cleanupGroups.append((id, name))
            }
            cleanup = CleanupNotes.toTemplates(cleanupRows) { nameToId[$0.lowercased()] }
            try await persistCleanupGroups(cleanup, named: cleanupGroups)
        }

        try await syncClient.storeCategoryAutomations(
            categoryId: categoryId,
            goalDef: templates.isEmpty ? nil : GoalTemplate.encodeArray(templates),
            cleanupDef: cleanup.isEmpty ? nil : CleanupTemplate.encodeArray(cleanup),
            source: "notes")
        try await database?.tombstoneOrphanCleanupGroups()
    }

    private func checkOutcome(
        rows: [BudgetDatabase.GoalTemplateCategoryRow],
        parsedNotes: [String: [GoalTemplate]],
        schedules: [GoalScheduleInfo]
    ) -> GoalTemplateOutcome {
        let scheduleNames = Set(schedules.compactMap(\.name))
        var errors: [String] = []
        for row in rows {
            guard let templates = parsedNotes[row.id] else { continue }
            for template in templates {
                if template.type == .error {
                    if let message = template.error, message.contains("adjustment") {
                        errors.append("\(row.name): \(template.line ?? "")\nError: \(message)")
                    } else {
                        errors.append("\(row.name): \(template.line ?? "")")
                    }
                } else if template.type == .schedule, let name = template.name,
                          !scheduleNames.contains(name) {
                    errors.append("\(row.name): Schedule \"\(name)\" does not exist")
                }
            }
        }
        return errors.isEmpty ? .checkPassed : .errors(errors)
    }
    
    // MARK: - Notes

    func fetchNote(id: String) async -> EntityNote {
        guard let database else { return .unsupported }
        do {
            return try await database.fetchNote(id: id)
        } catch {
            logger.error("Failed to read note: \(error.localizedDescription, privacy: .public)")
            return .unsupported
        }
    }

    func saveNote(id: String, note: String) async throws {
        guard let syncClient else {
            throw BudgetStoreError.syncNotConfigured
        }
        try await syncClient.setNote(id: id, note: note)
    }
    
    // MARK: - Rules

    @Published private(set) var rules: [Rule] = []
    @Published private(set) var scheduleOwnedRuleIds: Set<String> = []
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

    func saveRule(_ rule: Rule) async throws {
        guard let syncClient else { throw BudgetStoreError.syncNotConfigured }
        try Self.validate(rule)
        try await syncClient.saveRule(rule)
        await loadRules()
    }

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
            switch condition.op {
            case "oneOf", "notOneOf":
                guard condition.value.listValue?.isEmpty == false else {
                    throw BudgetStoreError.ruleEmptyValue(field: condition.field)
                }
            case "onBudget", "offBudget":
                break
            case "isbetween":
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
                    if condition.op == "matches" {
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
            if field == "account", action.value.stringValue?.isEmpty != false {
                throw BudgetStoreError.ruleEmptyValue(field: field)
            }
        }
    }
    
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

    func formatCurrency(_ cents: Int) -> String {
        CurrencyAmountFormat.string(
            cents: cents,
            currencyCode: currencyCode,
            narrowSymbol: useNarrowCurrencySymbol,
            numberFormat: numberFormat
        )
    }

    func formatCurrencyWholeUnits(_ cents: Int) -> String {
        CurrencyAmountFormat.string(
            cents: cents,
            currencyCode: currencyCode,
            narrowSymbol: useNarrowCurrencySymbol,
            wholeUnits: true,
            numberFormat: numberFormat
        )
    }

    // MARK: - Helpers

    private static let yearMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    private static let yearMonthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func currentMonthString() -> String {
        Self.yearMonthFormatter.string(from: Date())
    }
}
