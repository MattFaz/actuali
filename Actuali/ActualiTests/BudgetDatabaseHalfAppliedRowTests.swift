import Foundation
import Testing
import GRDB
@testable import Actuali

/// Pins the upstream `v_transactions_internal` validity filter (GH #275):
/// a CRDT update message for a row whose insert messages are gone from the
/// server's history (e.g. after a sync reset) materializes a half-applied
/// transaction row with a NULL `date` or `acct`. Upstream hides those rows
/// behind `date IS NOT NULL AND acct IS NOT NULL` in every view, so the
/// official client neither lists them nor counts them in balances — Actuali
/// must do the same or the row shows up as a phantom duplicate with a
/// garbage date and skews the account balance.
@MainActor
struct BudgetDatabaseHalfAppliedRowTests {

    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")

        let queue = try DatabaseQueue(path: tempURL.path)
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

                CREATE TABLE payees (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    transfer_acct TEXT,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE payee_mapping (
                    id TEXT PRIMARY KEY,
                    targetId TEXT
                );

                CREATE TABLE categories (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE category_mapping (
                    id TEXT PRIMARY KEY,
                    transferId TEXT
                );

                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    isParent INTEGER DEFAULT 0,
                    isChild INTEGER DEFAULT 0,
                    acct TEXT,
                    category TEXT,
                    description TEXT,
                    amount INTEGER,
                    notes TEXT,
                    date INTEGER,
                    imported_description TEXT,
                    financial_id TEXT,
                    transferred_id TEXT,
                    cleared INTEGER DEFAULT 0,
                    reconciled INTEGER DEFAULT 0,
                    sort_order REAL,
                    parent_id TEXT,
                    tombstone INTEGER DEFAULT 0
                );
            """)
        }
        let database = try BudgetDatabase(path: tempURL)
        return (database, tempURL)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// One healthy transfer leg plus a half-applied row (no date cell ever
    /// arrived) on the same account — the exact shape reported in GH #275.
    private func seed(_ db: BudgetDatabase) async throws {
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, sort_order) VALUES
                    ('acct-a', 'Bank', 1.0);

                INSERT INTO transactions (id, acct, amount, date, notes, cleared) VALUES
                    ('t-real', 'acct-a', -275425, 20251030, NULL, 1);

                -- Half-applied: update messages recreated the row without its
                -- date cell. Official clients hide it (date IS NOT NULL).
                INSERT INTO transactions (id, acct, amount, date, notes, cleared) VALUES
                    ('t-phantom', 'acct-a', -275425, NULL, 'VOTRE PAIEMENT', 1);

                -- Half-applied the other way round: no acct cell.
                INSERT INTO transactions (id, acct, amount, date, notes) VALUES
                    ('t-orphan', NULL, -5000, 20251101, 'stray');
            """)
        }
    }

    @Test func listHidesRowsWithoutDateOrAccount() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seed(db)

        let accountRows = try await db.fetchTransactions(accountId: "acct-a")
        #expect(accountRows.map(\.id) == ["t-real"])

        let allRows = try await db.fetchTransactions()
        #expect(allRows.map(\.id) == ["t-real"])
    }

    @Test func balancesExcludeRowsWithoutDate() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seed(db)

        let account = try #require(try await db.fetchAccounts().first { $0.id == "acct-a" })
        #expect(account.balance == -275425)

        let cleared = try await db.clearedBalance(accountId: "acct-a")
        #expect(cleared == -275425)

        let breakdown = try await db.balanceBreakdown(accountId: "acct-a")
        #expect(breakdown.cleared == -275425)
        #expect(breakdown.uncleared == 0)
    }

    /// Upstream's alive view joins the parent row of every child (is_child =
    /// 1) and requires it to exist with tombstone = 0, so a child whose
    /// parent row never materialized — or that lost its parent_id cell —
    /// counts nowhere.
    @Test func balancesExcludeChildrenOfMissingParents() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seed(db)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, amount, date, isChild, parent_id, cleared) VALUES
                    ('c-missing-parent', 'acct-a', -1000, 20251102, 1, 'never-arrived', 1),
                    ('c-null-parent',    'acct-a', -2000, 20251103, 1, NULL,            1);
            """)
        }

        let account = try #require(try await db.fetchAccounts().first { $0.id == "acct-a" })
        #expect(account.balance == -275425)

        let breakdown = try await db.balanceBreakdown(accountId: "acct-a")
        #expect(breakdown.cleared == -275425)

        let reportRows = try await db.fetchTransactionsForReports()
        #expect(reportRows.map(\.id) == ["t-real"])
    }

    @Test func singleFetchAndReportsHideHalfAppliedRows() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }
        try await seed(db)

        #expect(try await db.fetchTransaction(id: "t-phantom") == nil)
        #expect(try await db.fetchTransaction(id: "t-real") != nil)

        let reportRows = try await db.fetchTransactionsForReports()
        #expect(reportRows.map(\.id) == ["t-real"])
    }
}
