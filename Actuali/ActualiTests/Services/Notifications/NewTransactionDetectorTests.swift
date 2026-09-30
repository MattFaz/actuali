import Foundation
import GRDB
import Testing
@testable import Actuali

struct NewTransactionDetectorTests {
    private let localNode = "aaaaaaaaaaaaaaaa"
    private let serverNode = "bbbbbbbbbbbbbbbb"
    private let budgetId = "test-budget"

    private func makeDatabase() async throws -> BudgetDatabase {
        try await makeTestDatabase(TestSchema.core + ["INSERT INTO accounts (id, name) VALUES ('acct1', 'Checking')"]).0
    }

    private func makeDefaults() -> UserDefaults {
        let name = "NewTransactionDetectorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    /// Insert a transaction row plus its creation messages, attributed to
    /// `node`, the way a sync (or local write) populates messages_crdt.
    private func insertTransaction(_ database: BudgetDatabase, id: String,
                                   category: String? = nil, node: String) throws {
        try database.dbQueueForTesting.write { db in
            try db.execute(
                sql: "INSERT INTO transactions (id, acct, amount, date, category) VALUES (?, 'acct1', -1250, 20260707, ?)",
                arguments: [id, category]
            )
            for (i, column) in ["acct", "amount", "date"].enumerated() {
                let ts = String(format: "2026-07-07T00:00:00.%03dZ-0000-%@", i, node)
                try db.execute(
                    sql: "INSERT INTO messages_crdt (timestamp, dataset, row, column, value) VALUES (?, 'transactions', ?, ?, x'00')",
                    arguments: ["\(id)-\(ts)", id, column]
                )
            }
        }
    }

    private func editTransaction(_ database: BudgetDatabase, id: String, node: String) throws {
        try database.dbQueueForTesting.write { db in
            try db.execute(
                sql: "INSERT INTO messages_crdt (timestamp, dataset, row, column, value) VALUES (?, 'transactions', ?, 'notes', x'00')",
                arguments: ["\(id)-edit-2026-07-07T00:00:09.000Z-0000-\(node)", id]
            )
        }
    }

    @Test func firstRunReportsNothingEvenWithExistingServerTransactions() async throws {
        let database = try await makeDatabase()
        try insertTransaction(database, id: "t1", node: serverNode)
        let detector = NewTransactionDetector(defaults: makeDefaults())

        let found = try await detector.detectNewTransactions(
            in: database, budgetId: budgetId, localNode: localNode
        )

        #expect(found.isEmpty)
    }

    @Test func detectsServerTransactionOnceThenGoesQuiet() async throws {
        let database = try await makeDatabase()
        let detector = NewTransactionDetector(defaults: makeDefaults())
        _ = try await detector.detectNewTransactions(
            in: database, budgetId: budgetId, localNode: localNode
        )

        try insertTransaction(database, id: "t1", node: serverNode)

        let first = try await detector.detectNewTransactions(
            in: database, budgetId: budgetId, localNode: localNode
        )
        let second = try await detector.detectNewTransactions(
            in: database, budgetId: budgetId, localNode: localNode
        )

        #expect(first.map(\.id) == ["t1"])
        #expect(second.isEmpty)
    }

    @Test func ignoresLocallyCreatedTransactions() async throws {
        let database = try await makeDatabase()
        let detector = NewTransactionDetector(defaults: makeDefaults())
        _ = try await detector.detectNewTransactions(
            in: database, budgetId: budgetId, localNode: localNode
        )

        try insertTransaction(database, id: "local1", node: localNode)

        let found = try await detector.detectNewTransactions(
            in: database, budgetId: budgetId, localNode: localNode
        )

        #expect(found.isEmpty)
    }

    @Test func ignoresServerEditsToExistingTransactions() async throws {
        let database = try await makeDatabase()
        try insertTransaction(database, id: "t1", node: serverNode)
        let detector = NewTransactionDetector(defaults: makeDefaults())
        _ = try await detector.detectNewTransactions(
            in: database, budgetId: budgetId, localNode: localNode
        )

        try editTransaction(database, id: "t1", node: serverNode)

        let found = try await detector.detectNewTransactions(
            in: database, budgetId: budgetId, localNode: localNode
        )

        #expect(found.isEmpty)
    }

    @Test func watermarkSurvivesDetectorRecreation() async throws {
        let database = try await makeDatabase()
        let defaults = makeDefaults()
        _ = try await NewTransactionDetector(defaults: defaults).detectNewTransactions(
            in: database, budgetId: budgetId, localNode: localNode
        )

        try insertTransaction(database, id: "t1", node: serverNode)

        let first = try await NewTransactionDetector(defaults: defaults).detectNewTransactions(
            in: database, budgetId: budgetId, localNode: localNode
        )
        let second = try await NewTransactionDetector(defaults: defaults).detectNewTransactions(
            in: database, budgetId: budgetId, localNode: localNode
        )

        #expect(first.map(\.id) == ["t1"])
        #expect(second.isEmpty)
    }

    /// A re-downloaded budget file resets messages_crdt ids, leaving the
    /// stored watermark ahead of the database. The detector must re-seed
    /// rather than spuriously notify (or miss forever).
    @Test func reseedsWhenWatermarkIsAheadOfDatabase() async throws {
        let bigDatabase = try await makeDatabase()
        for i in 1...3 {
            try insertTransaction(bigDatabase, id: "t\(i)", node: serverNode)
        }
        let defaults = makeDefaults()
        let detector = NewTransactionDetector(defaults: defaults)
        _ = try await detector.detectNewTransactions(
            in: bigDatabase, budgetId: budgetId, localNode: localNode
        )

        // Fresh download: same budget id, far fewer messages.
        let freshDatabase = try await makeDatabase()
        try insertTransaction(freshDatabase, id: "t1", node: serverNode)

        let found = try await detector.detectNewTransactions(
            in: freshDatabase, budgetId: budgetId, localNode: localNode
        )

        #expect(found.isEmpty)

        // And detection still works going forward from the new baseline.
        try insertTransaction(freshDatabase, id: "t9", node: serverNode)
        let next = try await detector.detectNewTransactions(
            in: freshDatabase, budgetId: budgetId, localNode: localNode
        )
        #expect(next.map(\.id) == ["t9"])
    }
}
