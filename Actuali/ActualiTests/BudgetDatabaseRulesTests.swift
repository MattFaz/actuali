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

    @Test func fetchesLiveRulesOnly() throws { /* tombstone = 1 row excluded */ }
    @Test func returnsEmptyWithoutRulesTable() throws { /* includeRulesTable: false */ }
    @Test func rankedFetchOrdersLeastSpecificFirst() async throws { /* mirrors RuleRankerTests via SQL */ }
    @Test func schedulesOwningRulesAreReported() throws { /* schedules table with rule = 'r-1' */ }
    @Test func ruleContextMapsCategoriesAccountsAndPayees() throws { /* categories/accounts/payees seeds */ }
}
