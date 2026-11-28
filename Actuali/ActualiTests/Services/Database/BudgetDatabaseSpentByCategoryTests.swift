import Foundation
import GRDB
import Testing
@testable import Actuali

struct BudgetDatabaseSpentByCategoryTests {
    /// One grouped read with the Spent figure's rules: split children count
    /// and their parent doesn't, an orphaned child (tombstoned parent) and a
    /// deleted row count nowhere, off-budget accounts stay out, and a merged
    /// category's spending lands on the category it was merged into.
    @Test func spentByCategoryFollowsTheSpentFigureRules() async throws {
        let (db, url) = try await spendingDatabase("""
            INSERT INTO category_mapping (id, transferId) VALUES ('merged', 'food');
            INSERT INTO transactions (id, acct, category, amount, date, isParent, isChild, parent_id, tombstone) VALUES
                ('split',      'on',  'food',   -1000, 20261010, 1, 0, NULL, 0),
                ('split-a',    'on',  'food',    -600, 20261010, 0, 1, 'split', 0),
                ('split-b',    'on',  'fun',     -400, 20261010, 0, 1, 'split', 0),
                ('dead',       'on',  NULL,     -5000, 20261011, 1, 0, NULL, 1),
                ('orphan',     'on',  'food',   -5000, 20261011, 0, 1, 'dead', 0),
                ('deleted',    'on',  'food',   -5000, 20261012, 0, 0, NULL, 1),
                ('off-budget', 'off', 'food',   -5000, 20261012, 0, 0, NULL, 0),
                ('old-name',   'on',  'merged',  -700, 20261013, 0, 0, NULL, 0),
                ('after',      'on',  'food',   -5000, 20261016, 0, 0, NULL, 0);
        """)
        defer { cleanup(url) }

        let spent = try await db.spentByCategory(month: "2026-10", through: 20_261_015)

        #expect(spent == ["food": -1300, "fun": -400])
    }

    private func spendingDatabase(_ rows: String) async throws -> (BudgetDatabase, URL) {
        let (db, url) = try await makeTestDatabase(
            TestSchema.accounts, TestSchema.payees, TestSchema.payeeMapping,
            TestSchema.categories, TestSchema.categoryMapping, TestSchema.transactions
        )
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name, offbudget) VALUES ('on', 'Checking', 0), ('off', 'Brokerage', 1);
                INSERT INTO categories (id, name) VALUES ('food', 'Food'), ('fun', 'Fun'), ('secret', 'Secret');
                INSERT INTO category_mapping (id, transferId) VALUES ('food', NULL), ('fun', NULL), ('secret', NULL);
            """ + rows)
        }
        return (db, url)
    }
}
