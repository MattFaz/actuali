import Foundation
import Testing
import GRDB
@testable import Actuali

/// Pins the row set and fields of `fetchTransactionsForReports()`, which feeds
/// every dashboard widget engine:
/// - `transferAcct` must carry the payee's `transfer_acct` so report engines
///   can exclude transfers the way the WebUI does (GH #15: cash flow income
///   and expenses over 2x because transfer legs counted as both).
/// - Children of a tombstoned split parent must be excluded — deleting a
///   split tombstones only the parent, leaving live orphan child rows (same
///   rule `fetchAccounts()` already applies to balances).
@MainActor
struct BudgetDatabaseReportsFetchTests {

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

    @Test func populatesTransferAcctFromPayee() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name) VALUES
                    ('acct-checking', 'Checking'),
                    ('acct-savings',  'Savings');

                INSERT INTO payees (id, name, transfer_acct) VALUES
                    ('payee-shop',     'Coffee Shop', NULL),
                    ('payee-transfer', NULL,          'acct-savings');

                INSERT INTO payee_mapping (id, targetId) VALUES
                    ('payee-shop',     'payee-shop'),
                    ('payee-transfer', 'payee-transfer');

                INSERT INTO transactions (id, acct, description, amount, date, transferred_id) VALUES
                    ('t-spend',    'acct-checking', 'payee-shop',      -550,  20260601, NULL),
                    ('t-transfer', 'acct-checking', 'payee-transfer', -10000, 20260602, 't-other-leg');
            """)
        }

        let txns = try await db.fetchTransactionsForReports()
        let spend = txns.first { $0.id == "t-spend" }
        let transfer = txns.first { $0.id == "t-transfer" }

        #expect(spend?.transferAcct == nil)
        #expect(transfer?.transferAcct == "acct-savings")
    }

    @Test func excludesSplitParentsAndOrphanedChildren() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, amount, date, tombstone) VALUES
                    ('main', 'acct-1', 10000, 20260601, 0);

                -- A live split: children count, the parent must not.
                INSERT INTO transactions (id, acct, amount, date, isParent, isChild, parent_id, tombstone) VALUES
                    ('live-parent', 'acct-1', -10000, 20260602, 1, 0, NULL,          0),
                    ('live-c1',     'acct-1',  -6000, 20260602, 0, 1, 'live-parent', 0),
                    ('live-c2',     'acct-1',  -4000, 20260602, 0, 1, 'live-parent', 0);

                -- A deleted split: the parent is tombstoned but its children
                -- still carry tombstone = 0. Neither may appear in reports.
                INSERT INTO transactions (id, acct, amount, date, isParent, isChild, parent_id, tombstone) VALUES
                    ('dead-parent', 'acct-1', -1000, 20260603, 1, 0, NULL,          1),
                    ('orphan-c1',   'acct-1',  -500, 20260603, 0, 1, 'dead-parent', 0),
                    ('orphan-c2',   'acct-1',  -500, 20260603, 0, 1, 'dead-parent', 0);
            """)
        }

        let ids = try await db.fetchTransactionsForReports().map(\.id).sorted()
        #expect(ids == ["live-c1", "live-c2", "main"])
    }

    // MARK: - custom_reports configs

    @Test func fetchesCustomReportConfigs() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            // A synced budget file carries upstream columns the app's own
            // migration doesn't create; add them so the fetch reads real values.
            try conn.execute(sql: """
                ALTER TABLE custom_reports ADD COLUMN date_static INTEGER DEFAULT 0;
                ALTER TABLE custom_reports ADD COLUMN include_current INTEGER DEFAULT 0;
                ALTER TABLE custom_reports ADD COLUMN sort_by TEXT DEFAULT 'desc';

                INSERT INTO custom_reports
                    (id, name, mode, group_by, balance_type, interval, graph_type,
                     date_range, date_static, start_date, end_date, include_current,
                     show_empty, show_offbudget, show_hidden, show_uncategorized,
                     sort_by, conditions, conditions_op, tombstone)
                VALUES
                    ('r1', 'Category Spending', 'total', 'Category', 'Payment', 'Monthly',
                     'BarGraph', 'All time', 0, '2025-08-30', '2026-04-26', 1,
                     0, 0, 0, 0, 'name',
                     '[{"field":"transfer","op":"is","value":false,"type":"boolean"}]',
                     'and', 0),
                    ('r2', 'Deleted', 'total', 'Category', 'Payment', 'Monthly',
                     'BarGraph', 'All time', 0, NULL, NULL, 1,
                     0, 0, 0, 0, 'desc', NULL, 'and', 1);
            """)
        }

        let configs = try await db.fetchCustomReportConfigs(ids: ["r1", "r2", "missing"])
        #expect(configs.count == 1)
        let r1 = try #require(configs["r1"])
        #expect(r1.name == "Category Spending")
        #expect(r1.mode == "total")
        #expect(r1.groupBy == "Category")
        #expect(r1.balanceType == "Payment")
        #expect(r1.graphType == "BarGraph")
        #expect(r1.dateRange == "All time")
        #expect(r1.dateStatic == false)
        #expect(r1.includeCurrent == true)
        #expect(r1.sortBy == "name")
        #expect(r1.startDate == "2025-08-30")
        #expect(r1.endDate == "2026-04-26")
        #expect(r1.conditions?.first?.field == "transfer")
        #expect(r1.conditionsOp == "and")

        let empty = try await db.fetchCustomReportConfigs(ids: [])
        #expect(empty.isEmpty)
    }

    /// The app's own migration creates `custom_reports` without upstream's
    /// later columns (date_static, include_current, sort_by); the fetch must
    /// default them instead of failing.
    @Test func fetchesCustomReportConfigsWhenUpstreamColumnsMissing() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO custom_reports
                    (id, name, mode, group_by, balance_type, interval, graph_type,
                     date_range, conditions, conditions_op, tombstone)
                VALUES
                    ('r1', 'Net Worth', 'time', 'Group', 'Net', 'Weekly',
                     'LineGraph', 'Year to date', NULL, 'or', 0)
            """)
        }

        let configs = try await db.fetchCustomReportConfigs(ids: ["r1"])
        let r1 = try #require(configs["r1"])
        #expect(r1.name == "Net Worth")
        #expect(r1.interval == "Weekly")
        #expect(r1.dateStatic == false)
        #expect(r1.includeCurrent == false)
        #expect(r1.sortBy == "desc")
        #expect(r1.conditions == nil)
        #expect(r1.conditionsOp == "or")
    }

    // MARK: - firstDayOfWeekIdx preference

    @Test func firstDayOfWeekDefaultsToSunday() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        // No preferences table in this fixture: must default to 0 (Sunday).
        #expect(try await db.fetchFirstDayOfWeekIdx() == 0)
    }

    @Test func firstDayOfWeekReadsPreference() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
                INSERT INTO preferences (id, value) VALUES ('firstDayOfWeekIdx', '1');
            """)
        }

        #expect(try await db.fetchFirstDayOfWeekIdx() == 1)
    }

    @Test func firstDayOfWeekDefaultsWhenRowMissingOrInvalid() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
                INSERT INTO preferences (id, value) VALUES ('defaultCurrencyCode', 'USD');
            """)
        }
        #expect(try await db.fetchFirstDayOfWeekIdx() == 0)

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO preferences (id, value) VALUES ('firstDayOfWeekIdx', 'bogus');
            """)
        }
        #expect(try await db.fetchFirstDayOfWeekIdx() == 0)
    }
}
