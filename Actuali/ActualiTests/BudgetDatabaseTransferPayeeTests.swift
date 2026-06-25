import Foundation
import Testing
import GRDB
@testable import Actuali

/// Pins payee-name resolution in `fetchTransactions()`: a transfer's payee row
/// carries no name (only `transfer_acct`), so its display name must come from
/// the linked account — matching Actual's `v_payees` view
/// (`COALESCE(__accounts.name, _.name)`). Regular payees keep their own name.
/// Regression for GH #7: transfers rendered with an empty payee.
@MainActor
struct BudgetDatabaseTransferPayeeTests {

    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")

        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT,
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

    @Test func transferPayeeResolvesToLinkedAccountName() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name) VALUES
                    ('acct-checking', 'Checking'),
                    ('acct-savings',  'Savings');

                -- A regular payee (has its own name) and a transfer payee
                -- (no name, transfer_acct points at Savings).
                INSERT INTO payees (id, name, transfer_acct) VALUES
                    ('payee-shop',     'Coffee Shop', NULL),
                    ('payee-transfer', NULL,          'acct-savings');

                INSERT INTO payee_mapping (id, targetId) VALUES
                    ('payee-shop',     'payee-shop'),
                    ('payee-transfer', 'payee-transfer');

                -- One normal spend and one transfer leg out of Checking.
                INSERT INTO transactions (id, acct, description, amount, date, transferred_id) VALUES
                    ('t-spend',    'acct-checking', 'payee-shop',     -550,  20260601, NULL),
                    ('t-transfer', 'acct-checking', 'payee-transfer', -10000, 20260602, 't-other-leg');
            """)
        }

        let txns = try await db.fetchTransactions(accountId: "acct-checking")
        let spend = txns.first { $0.id == "t-spend" }
        let transfer = txns.first { $0.id == "t-transfer" }

        #expect(spend?.payeeName == "Coffee Shop")
        #expect(transfer?.payeeName == "Savings")
    }
}
