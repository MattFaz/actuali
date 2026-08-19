import Foundation
import Testing
import GRDB
@testable import Actuali

/// Regression coverage for actios-tq4w: the Log Transaction Shortcut failed
/// with "Couldn't save transaction (Open Actuali and select a budget first)"
/// after app updates or a long background idle. Those are cold headless
/// launches, where the init()-time budget load can fail transiently (e.g.
/// SQLITE_BUSY against the entity query's temporary connection).
/// `ensureBudgetReady()` cached that single failed `loadTask` for the whole
/// process lifetime, so every later automation run saw a nil database even
/// though the file on disk opens fine.
@MainActor
struct BudgetStoreEnsureBudgetReadyTests {

    /// Creates a real on-disk budget in the app-support Budgets directory so
    /// `ensureBudgetReady()`'s `budgetExists` guard and `loadLocalBudget`'s
    /// open run against production paths. Unique id per test: suites run in
    /// parallel and must not share budget directories.
    private func makeOnDiskBudget() throws -> String {
        let budgetId = "test-ensure-ready-\(UUID().uuidString)"
        let dir = BudgetFileManager.shared.budgetDirectory(for: budgetId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let queue = try DatabaseQueue(path: BudgetFileManager.shared.databasePath(for: budgetId).path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    type TEXT,
                    offbudget INTEGER DEFAULT 0,
                    closed INTEGER DEFAULT 0,
                    sort_order REAL,
                    tombstone INTEGER DEFAULT 0
                );

                INSERT INTO accounts (id, name, type, sort_order)
                VALUES ('acct-1', 'Checking', 'checking', 1.0);
            """)
        }
        return budgetId
    }

    private func cleanup(budgetId: String, savedDefault: String?) {
        try? BudgetFileManager.shared.deleteBudget(budgetId)
        // currentBudgetId's didSet persists to UserDefaults; restore so tests
        // don't leak state into the host app's defaults.
        UserDefaults.standard.set(savedDefault, forKey: "currentBudgetId")
    }

    /// The bug: an init()-time load that failed must not be cached — the next
    /// `ensureBudgetReady()` retries and opens the (healthy) database.
    @Test func retriesAfterFailedInitialLoad() async throws {
        let savedDefault = UserDefaults.standard.string(forKey: "currentBudgetId")
        let budgetId = try makeOnDiskBudget()
        defer { cleanup(budgetId: budgetId, savedDefault: savedDefault) }

        let store = BudgetStore.previewInstance()
        store.currentBudgetId = budgetId
        store.simulateFailedInitialLoadForTesting()
        #expect(store.databaseForLogger == nil)

        await store.ensureBudgetReady()

        #expect(store.databaseForLogger != nil)
    }

    /// Pre-existing behavior: a freshly spawned headless process with no
    /// in-flight load starts one and awaits it.
    @Test func startsLoadWhenNoTaskIsInFlight() async throws {
        let savedDefault = UserDefaults.standard.string(forKey: "currentBudgetId")
        let budgetId = try makeOnDiskBudget()
        defer { cleanup(budgetId: budgetId, savedDefault: savedDefault) }

        let store = BudgetStore.previewInstance()
        store.currentBudgetId = budgetId

        await store.ensureBudgetReady()

        #expect(store.databaseForLogger != nil)
    }

    /// No budget selected: the retry path must not spin or crash — there is
    /// genuinely nothing to load.
    @Test func doesNothingWhenNoBudgetIsSelected() async throws {
        let savedDefault = UserDefaults.standard.string(forKey: "currentBudgetId")
        defer { UserDefaults.standard.set(savedDefault, forKey: "currentBudgetId") }

        let store = BudgetStore.previewInstance()
        store.currentBudgetId = nil
        store.simulateFailedInitialLoadForTesting()

        await store.ensureBudgetReady()

        #expect(store.databaseForLogger == nil)
    }
}
