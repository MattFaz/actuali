import Foundation
import GRDB
import Testing

@testable import Actuali

/// Switching budgets must land on the new budget's currency, not carry the
/// previous one over (GH #297). The database is authoritative whenever it has
/// an answer; the per-budget cache only covers a freshly downloaded snapshot
/// that predates the CRDT preference messages carrying the setting.
@MainActor
struct BudgetStoreCurrencyRefreshTests {

    /// Store rooted in a unique temp directory. The currency cache lives in
    /// UserDefaults keyed by budget id, and suites run in parallel, so both
    /// the files and the ids have to be unique per test.
    private func makeStore() throws -> (BudgetStore, BudgetFileManager, String, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("currency-tests-\(UUID().uuidString)", isDirectory: true)
        let manager = BudgetFileManager(rootDirectoryForTesting: root)
        let store = BudgetStore.previewInstance()
        store.setFileManagerForTesting(manager)
        return (store, manager, "budget-\(UUID().uuidString)", root)
    }

    /// An on-disk budget with the full schema loadLocalBudget reads. `groupId`
    /// stays nil so the load leaves sync unconfigured and nothing reaches the
    /// network — the currency paths under test are pure database reads.
    private func seedBudget(
        id: String, currency: String?, in manager: BudgetFileManager
    ) throws {
        let dir = manager.budgetDirectory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbQueue = try DatabaseQueue(path: manager.databasePath(for: id).path)
        try dbQueue.write { db in
            try db.execute(sql: BudgetStoreInitialSyncTests.upstreamSchema)
        }
        try JSONEncoder().encode(BudgetMetadata(
            id: id, budgetName: "Seed", cloudFileId: "cf-1", groupId: nil,
            resetClock: nil, lastUploaded: nil, encryptKeyId: nil
        )).write(to: manager.metadataPath(for: id))
        if let currency {
            try setCurrency(currency, id: id, in: manager)
        }
    }

    /// Write the preference the way a sync would, straight into the table.
    private func setCurrency(_ code: String?, id: String, in manager: BudgetFileManager) throws {
        let dbQueue = try DatabaseQueue(path: manager.databasePath(for: id).path)
        try dbQueue.write { db in
            if let code {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO preferences (id, value) VALUES ('defaultCurrencyCode', ?)",
                    arguments: [code])
            } else {
                try db.execute(sql: "DELETE FROM preferences WHERE id = 'defaultCurrencyCode'")
            }
        }
    }

    // MARK: - Load

    @Test func loadAppliesStoredCurrency() async throws {
        let (store, manager, id, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBudget(id: id, currency: "CAD", in: manager)

        store.currencyCode = "CHF"   // the budget we are switching away from
        await store.loadLocalBudget(id)

        #expect(store.currencyCode == "CAD")
    }

    /// No preference row at all: Actual only writes one once the user picks a
    /// currency, so the current value has to survive rather than be blanked.
    @Test func loadKeepsCurrentCurrencyWhenPreferenceIsAbsent() async throws {
        let (store, manager, id, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBudget(id: id, currency: nil, in: manager)

        store.currencyCode = "CHF"
        await store.loadLocalBudget(id)

        #expect(store.currencyCode == "CHF")
    }

    /// An empty value is Actual's explicit "None" setting, distinct from an
    /// absent row — amounts render as plain numbers.
    @Test func loadAppliesEmptyPreferenceAsNone() async throws {
        let (store, manager, id, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBudget(id: id, currency: "", in: manager)

        store.currencyCode = "CHF"
        await store.loadLocalBudget(id)

        #expect(store.currencyCode.isEmpty)
        #expect(!store.formatCurrency(123_450).contains("CHF"))
    }

    /// The cache must never outrank a snapshot that has the answer, or a
    /// currency changed on another client would stay hidden for the whole
    /// session whenever the correcting sync fails.
    @Test func storedCurrencyOutranksCachedCurrency() async throws {
        let (store, manager, id, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBudget(id: id, currency: "USD", in: manager)

        await store.loadLocalBudget(id)   // caches USD
        #expect(store.currencyCode == "USD")

        try setCurrency("GBP", id: id, in: manager)
        await store.loadLocalBudget(id)

        #expect(store.currencyCode == "GBP")
    }

    /// The one job the cache has: a re-downloaded snapshot whose preference
    /// messages have not been applied yet must still show this budget's
    /// currency, not the one belonging to the budget we came from.
    @Test func cachedCurrencyCoversASnapshotMissingThePreference() async throws {
        let (store, manager, id, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBudget(id: id, currency: "GBP", in: manager)

        await store.loadLocalBudget(id)   // caches GBP
        #expect(store.currencyCode == "GBP")

        try setCurrency(nil, id: id, in: manager)
        store.currencyCode = "CHF"        // the budget we are switching away from
        await store.loadLocalBudget(id)

        #expect(store.currencyCode == "GBP")
    }

    // MARK: - Refresh

    /// GH #297 proper: the downloaded snapshot trails the preference messages,
    /// so the currency only appears once sync applies them. refreshDataOnly()
    /// runs after every sync and is what has to pick it up.
    @Test func refreshAppliesCurrencyArrivingBySync() async throws {
        let (store, manager, id, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBudget(id: id, currency: nil, in: manager)

        store.currencyCode = "CHF"
        store.currentBudgetId = id
        await store.loadLocalBudget(id)
        #expect(store.currencyCode == "CHF")   // nothing in the snapshot yet

        try setCurrency("CAD", id: id, in: manager)   // as the first sync would
        await store.resetSyncState()                  // no sync client: refresh only

        #expect(store.currencyCode == "CAD")
    }

    /// A refresh must not blank the currency for a budget that has no
    /// preference row — every local write goes through this path.
    @Test func refreshKeepsCurrentCurrencyWhenPreferenceIsAbsent() async throws {
        let (store, manager, id, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBudget(id: id, currency: nil, in: manager)

        store.currencyCode = "CHF"
        store.currentBudgetId = id
        await store.loadLocalBudget(id)
        await store.resetSyncState()

        #expect(store.currencyCode == "CHF")
    }

    // MARK: - Cleanup

    /// Disconnecting wipes the local budgets, so their cached currencies must
    /// go too — a stale one would otherwise outlive the files and reappear if
    /// the same budget were ever downloaded again.
    @Test func logoutForgetsCachedCurrencies() async throws {
        let (store, manager, id, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try seedBudget(id: id, currency: "GBP", in: manager)

        await store.loadLocalBudget(id)   // caches GBP
        #expect(store.currencyCode == "GBP")

        store.logout()

        // Same budget id downloaded again, this time from a snapshot whose
        // preference messages have not landed: nothing may resurface.
        try seedBudget(id: id, currency: nil, in: manager)
        store.currencyCode = "CHF"
        await store.loadLocalBudget(id)

        #expect(store.currencyCode == "CHF")
    }
}
