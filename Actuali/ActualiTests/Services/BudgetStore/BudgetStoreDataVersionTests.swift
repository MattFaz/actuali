import Foundation
import GRDB
import Testing
@testable import Actuali

/// `dataVersion` is the store's change signal: views that cache their own
/// fetches (transaction pagers, report widgets) key reloads on it, so it must
/// bump whenever the published data snapshot is republished — after a local
/// mutation and after a sync.
@MainActor
struct BudgetStoreDataVersionTests {
    /// Every table `refreshDataOnly()` reads, so the refresh completes
    /// without error.
    private func makeDatabase() async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase(TestSchema.core + ["""
        INSERT INTO accounts (id, name, type, sort_order) VALUES
            ('acct-1', 'Checking', 'checking', 1.0);
        INSERT INTO transactions (id, acct, amount, date, cleared, sort_order) VALUES
            ('t1', 'acct-1', -500, 20260701, 0, 1.0);
        """])
    }

    @Test func localMutationBumpsDataVersion() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        let before = store.dataVersion

        // The cross-tab scenario the signal exists for: a dot-tap toggle on
        // one screen must announce itself to every cached list.
        let transaction = Transaction(
            id: "t1",
            accountId: "acct-1",
            date: 20_260_701,
            amount: -500,
            payeeId: nil,
            payeeName: nil,
            categoryId: nil,
            categoryName: nil,
            notes: nil,
            cleared: false,
            reconciled: false,
            transferId: nil,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: 1,
            importedPayee: nil
        )
        await store.toggleCleared(transaction)

        #expect(store.error == nil)
        #expect(store.dataVersion > before)
    }

    @Test func syncBumpsDataVersion() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)
        let before = store.dataVersion

        await store.sync()

        #expect(store.error == nil)
        #expect(store.dataVersion > before)
    }

    @Test func syncPreservesBrowsedBudgetMonth() async throws {
        let (database, url) = try await makeDatabase()
        defer { cleanup(url) }
        let store = try await makeTestStore(database: database)

        await store.fetchBudgetMonth("2026-06")
        #expect(store.currentBudgetMonth?.month == "2026-06")

        // Foreground sync and pull-to-refresh share this refresh pipeline.
        // It must refresh the selected historical month, not publish today's
        // calendar month underneath an unchanged month toolbar.
        await store.sync()

        #expect(store.error == nil)
        #expect(store.currentBudgetMonth?.month == "2026-06")
        // Widgets always show the current calendar month, even while the app
        // is browsing a historical budget.
        #expect(store.widgetBudgetMonth?.month == BudgetView.currentMonthString())
    }
}
