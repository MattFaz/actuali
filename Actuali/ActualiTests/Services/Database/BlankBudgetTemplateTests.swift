import Foundation
import GRDB
import Testing

@testable import Actuali

/// The bundled blank-budget template (GH #387) must look exactly like a file
/// upstream Actual created itself: default-db.sqlite plus every upstream
/// migration, and nothing Actuali-specific. Desktop/web validate a downloaded
/// file's __migrations__ against their migrations directory
/// (checkDatabaseValidity), so any Actuali-only id here would make the
/// created budget unopenable elsewhere. Regenerate the template with
/// dev/scripts/gen-blank-budget.mjs — never hand-edit it.
struct BlankBudgetTemplateTests {
    private func templateURL() throws -> URL {
        try #require(Bundle.main.url(forResource: "blank-budget", withExtension: "sqlite"))
    }

    /// Copy the bundled template out of the app bundle before opening it:
    /// BudgetDatabase records migration bookkeeping on open, and the simulator
    /// would happily write into the bundle.
    private func templateCopy() throws -> URL {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("blank-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: try templateURL(), to: copy)
        return copy
    }

    @Test func templateIsPristineUpstreamFile() throws {
        let url = try templateCopy()
        defer { try? FileManager.default.removeItem(at: url) }
        let queue = try DatabaseQueue(path: url.path)

        try queue.read { db in
            // A complete, purely-upstream migration set. 1780606215001
            // (bank-sync indexes) is the newest migration in the release the
            // template was generated from (v26.8.1); its presence proves the
            // template was fully migrated rather than left at
            // default-db.sqlite's base schema.
            let ids = try Int64.fetchAll(db, sql: "SELECT id FROM __migrations__ ORDER BY id")
            #expect(ids.count >= 57)
            #expect(ids.contains(1780606215001))
            #expect(Set(ids).isDisjoint(with: BudgetDatabase.actualiOnlyMigrationIds))

            // No sync history and no clock: the first client to open the file
            // mints its own node id, exactly like a fresh upstream budget.
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_clock") == 0)

            // Upstream's default categories ship inside default-db.sqlite.
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM category_groups") == 3)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM categories") == 7)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM category_mapping") == 7)

            // Empty caches — upstream never uploads kvcache contents.
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM kvcache") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM preferences") == 0)
        }
    }

    @Test func templateOpensInBudgetDatabase() async throws {
        let url = try templateCopy()
        defer { try? FileManager.default.removeItem(at: url) }

        let database = try BudgetDatabase(path: url)
        let groups = try await database.fetchCategoryGroups()
        #expect(groups.map(\.name).contains("Usual Expenses"))
        let accounts = try await database.fetchAccounts()
        let payees = try await database.fetchPayees()
        #expect(accounts.isEmpty)
        #expect(payees.isEmpty)
    }
}
