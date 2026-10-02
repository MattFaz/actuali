import Foundation
import GRDB
import Testing
@testable import Actuali

struct BudgetDatabaseApplyMessagesTests {
    /// accounts and messages_crdt normally come from the downloaded budget
    /// file, so create them with the upstream schema.
    private func makeDatabase() async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase(TestSchema.accounts, TestSchema.messagesCrdt)
    }

    private func message(
        millis: Int64,
        dataset: String = "accounts",
        row: String = "acct-1",
        column: String = "name",
        value: String = "S:Checking"
    ) -> CRDTMessage {
        CRDTMessage(
            timestamp: HLCTimestamp(millis: millis, counter: 0, node: "89e0e8e90b203f9e"),
            dataset: dataset,
            row: row,
            column: column,
            value: value
        )
    }

    private func accountName(path: URL, id: String) throws -> String? {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM accounts WHERE id = ?", arguments: [id])
        }
    }

    @Test func maliciousDatasetIsSkippedWithoutThrowing() async throws {
        let (database, path) = try await makeDatabase()
        let malicious = message(
            millis: 1_700_000_000_000,
            dataset: "accounts; DROP TABLE accounts;--"
        )
        let legit = message(millis: 1_700_000_000_001, value: "S:Savings")

        try database.applyMessages([malicious, legit])

        let queue = try DatabaseQueue(path: path.path)
        let accountsExists = try await queue.read { db in try db.tableExists("accounts") }
        #expect(accountsExists)
        #expect(try accountName(path: path, id: "acct-1") == "Savings")
    }

    @Test func maliciousColumnIsSkippedWithoutThrowing() async throws {
        let (database, path) = try await makeDatabase()
        try database.applyMessages([
            message(millis: 1_700_000_000_000, row: "acct-1", value: "S:Checking"),
            message(millis: 1_700_000_000_001, row: "acct-2", value: "S:Savings"),
        ])

        let malicious = message(
            millis: 1_700_000_000_002,
            row: "acct-1",
            column: "name\" = 'x' WHERE 1=1; --",
            value: "S:evil"
        )
        try database.applyMessages([malicious])

        #expect(try accountName(path: path, id: "acct-1") == "Checking")
        #expect(try accountName(path: path, id: "acct-2") == "Savings")
    }

    @Test func unknownUpstreamTableIsSkippedGracefully() async throws {
        let (database, path) = try await makeDatabase()
        let driftTable = message(millis: 1_700_000_000_000, dataset: "preferences", column: "value")
        let driftColumn = message(millis: 1_700_000_000_001, column: "last_reconciled")
        let legit = message(millis: 1_700_000_000_002, value: "S:Checking")

        try database.applyMessages([driftTable, driftColumn, legit])

        #expect(try accountName(path: path, id: "acct-1") == "Checking")
    }

    @Test func legitMessagesInsertAndUpdate() async throws {
        let (database, path) = try await makeDatabase()

        try database.applyMessages([message(millis: 1_700_000_000_000, value: "S:Checking")])
        #expect(try accountName(path: path, id: "acct-1") == "Checking")

        try database.applyMessages([message(millis: 1_700_000_000_001, value: "S:Renamed")])
        #expect(try accountName(path: path, id: "acct-1") == "Renamed")
    }

    @Test func outOfOrderBatchConvergesToOrderedResult() async throws {
        let earlier = message(millis: 1_700_000_000_000, value: "S:Old Name")
        let later = message(millis: 1_700_000_000_001, value: "S:New Name")

        let (orderedDb, orderedPath) = try await makeDatabase()
        try orderedDb.applyMessages([earlier, later])

        let (reversedDb, reversedPath) = try await makeDatabase()
        try reversedDb.applyMessages([later, earlier])

        #expect(try accountName(path: orderedPath, id: "acct-1") == "New Name")
        #expect(try accountName(path: reversedPath, id: "acct-1") == "New Name")
    }
}
