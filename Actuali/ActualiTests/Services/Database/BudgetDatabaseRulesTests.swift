import Foundation
import GRDB
import Testing
@testable import Actuali

struct BudgetDatabaseRulesTests {

    private func makeDatabase(includeRulesTable: Bool = true, seedSQL: String = "") throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            if includeRulesTable {
                try db.execute(sql: """
                    CREATE TABLE rules (id TEXT PRIMARY KEY, stage TEXT, conditions TEXT,
                                        actions TEXT, tombstone INTEGER DEFAULT 0,
                                        conditions_op TEXT DEFAULT 'and');
                    """)
            }
            if !seedSQL.isEmpty { try db.execute(sql: seedSQL) }
        }
        return (try BudgetDatabase(path: tempURL), tempURL)
    }

    private func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    @Test func fetchesLiveRulesOnly() throws {
        let (database, path) = try makeDatabase(seedSQL: """
            INSERT INTO rules (id, stage, conditions_op, conditions, actions, tombstone) VALUES
              ('r-live', NULL, 'and',
               '[{"op":"is","field":"description","value":"payee-1","type":"id"}]',
               '[{"op":"set","field":"category","value":"cat-1","type":"id"}]', 0),
              ('r-dead', NULL, 'and',
               '[{"op":"is","field":"description","value":"payee-2","type":"id"}]',
               '[{"op":"set","field":"category","value":"cat-2","type":"id"}]', 1);
            """)
        defer { cleanup(path) }

        let rules = try database.fetchRules()

        #expect(rules.map(\.id) == ["r-live"])
        // Internal column names come back out as public rule field names.
        #expect(rules[0].conditions[0].field == "payee")
    }

    @Test func returnsEmptyWithoutRulesTable() throws {
        let (database, path) = try makeDatabase(includeRulesTable: false)
        defer { cleanup(path) }

        #expect(try database.rulesTableExists() == false)
        #expect(try database.fetchRules().isEmpty)
    }

    /// `fetchRulesRanked` mirrors upstream `rules-get`: least specific first
    /// within a stage, and `post` after `default`.
    @Test func rankedFetchOrdersLeastSpecificFirst() async throws {
        let (database, path) = try makeDatabase(seedSQL: """
            INSERT INTO rules (id, stage, conditions_op, conditions, actions, tombstone) VALUES
              ('r-exact', NULL, 'and',
               '[{"op":"is","field":"imported_description","value":"coffee co","type":"string"}]',
               '[{"op":"set","field":"category","value":"cat-1","type":"id"}]', 0),
              ('r-broad', NULL, 'and',
               '[{"op":"contains","field":"imported_description","value":"coffee","type":"string"}]',
               '[{"op":"set","field":"category","value":"cat-2","type":"id"}]', 0),
              ('r-post', 'post', 'and',
               '[{"op":"contains","field":"imported_description","value":"coffee","type":"string"}]',
               '[{"op":"set","field":"category","value":"cat-3","type":"id"}]', 0);
            """)
        defer { cleanup(path) }

        let ranked = try await database.fetchRulesRanked()

        #expect(ranked.map(\.id) == ["r-broad", "r-exact", "r-post"])
    }

    @Test func schedulesOwningRulesAreReported() throws {
        let (database, path) = try makeDatabase(seedSQL: """
            CREATE TABLE IF NOT EXISTS schedules
              (id TEXT PRIMARY KEY, rule TEXT, tombstone INTEGER DEFAULT 0);
            INSERT INTO schedules (id, rule, tombstone) VALUES
              ('s-1', 'r-owned', 0),
              ('s-dead', 'r-was-owned', 1),
              ('s-norule', NULL, 0);
            """)
        defer { cleanup(path) }

        #expect(try database.scheduleOwnedRuleIds() == ["r-owned"])
    }

    @Test func ruleContextMapsCategoriesAccountsAndPayees() throws {
        let (database, path) = try makeDatabase(seedSQL: """
            CREATE TABLE IF NOT EXISTS accounts
              (id TEXT PRIMARY KEY, name TEXT, offbudget INTEGER DEFAULT 0,
               closed INTEGER DEFAULT 0, tombstone INTEGER DEFAULT 0);
            CREATE TABLE IF NOT EXISTS categories
              (id TEXT PRIMARY KEY, name TEXT, cat_group TEXT, tombstone INTEGER DEFAULT 0);
            CREATE TABLE IF NOT EXISTS payees
              (id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, tombstone INTEGER DEFAULT 0);
            INSERT INTO accounts (id, name, offbudget) VALUES
              ('acct-on', 'Checking', 0), ('acct-off', 'Mortgage', 1);
            INSERT INTO categories (id, name, cat_group) VALUES ('cat-food', 'Food', 'grp-daily');
            INSERT INTO payees (id, name) VALUES ('payee-1', 'Woolworths');
            """)
        defer { cleanup(path) }

        let context = try database.ruleContext()

        #expect(context.offBudgetAccountIds == ["acct-off"])
        #expect(context.categoryGroupIds["cat-food"] == "grp-daily")
        #expect(context.payeeNames["payee-1"] == "Woolworths")
    }

    /// `payee(named:)` backs the `set payee_name` action, which must reuse an
    /// existing payee rather than creating a second one that differs by case.
    @Test func findsPayeeByNameCaseInsensitively() throws {
        let (database, path) = try makeDatabase(seedSQL: """
            CREATE TABLE IF NOT EXISTS payees
              (id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, tombstone INTEGER DEFAULT 0);
            INSERT INTO payees (id, name, tombstone) VALUES
              ('payee-1', 'Woolworths', 0), ('payee-dead', 'Aldi', 1);
            """)
        defer { cleanup(path) }

        #expect(try database.payee(named: "woolworths")?.id == "payee-1")
        #expect(try database.payee(named: "WOOLWORTHS")?.id == "payee-1")
        #expect(try database.payee(named: "Aldi") == nil)
        #expect(try database.payee(named: "Nowhere") == nil)
    }
}
