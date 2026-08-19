import Foundation
import Testing
import GRDB
@testable import Actuali

struct BudgetDatabaseApplyMessagesTests {

    /// accounts and messages_crdt normally come from the downloaded budget
    /// file, so create them with the upstream schema.
    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    offbudget INTEGER DEFAULT 0,
                    closed INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0
                )
                """)
            try db.execute(sql: """
                CREATE TABLE messages_crdt (
                    id INTEGER PRIMARY KEY,
                    timestamp TEXT NOT NULL UNIQUE,
                    dataset TEXT NOT NULL,
                    row TEXT NOT NULL,
                    column TEXT NOT NULL,
                    value BLOB NOT NULL
                )
                """)
        }
        return (try BudgetDatabase(path: tempURL), tempURL)
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

    @Test func maliciousDatasetIsSkippedWithoutThrowing() throws {
        let (database, path) = try makeDatabase()
        let malicious = message(
            millis: 1_700_000_000_000,
            dataset: "accounts; DROP TABLE accounts;--"
        )
        let legit = message(millis: 1_700_000_000_001, value: "S:Savings")

        try database.applyMessages([malicious, legit])

        let queue = try DatabaseQueue(path: path.path)
        let accountsExists = try queue.read { db in try db.tableExists("accounts") }
        #expect(accountsExists)
        #expect(try accountName(path: path, id: "acct-1") == "Savings")
    }

    @Test func maliciousColumnIsSkippedWithoutThrowing() throws {
        let (database, path) = try makeDatabase()
        try database.applyMessages([
            message(millis: 1_700_000_000_000, row: "acct-1", value: "S:Checking"),
            message(millis: 1_700_000_000_001, row: "acct-2", value: "S:Savings")
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

    @Test func unknownUpstreamTableIsSkippedGracefully() throws {
        let (database, path) = try makeDatabase()
        let driftTable = message(millis: 1_700_000_000_000, dataset: "preferences", column: "value")
        let driftColumn = message(millis: 1_700_000_000_001, column: "last_reconciled")
        let legit = message(millis: 1_700_000_000_002, value: "S:Checking")

        try database.applyMessages([driftTable, driftColumn, legit])

        #expect(try accountName(path: path, id: "acct-1") == "Checking")
    }

    @Test func legitMessagesInsertAndUpdate() throws {
        let (database, path) = try makeDatabase()

        try database.applyMessages([message(millis: 1_700_000_000_000, value: "S:Checking")])
        #expect(try accountName(path: path, id: "acct-1") == "Checking")

        try database.applyMessages([message(millis: 1_700_000_000_001, value: "S:Renamed")])
        #expect(try accountName(path: path, id: "acct-1") == "Renamed")
    }

    @Test func outOfOrderBatchConvergesToOrderedResult() throws {
        let earlier = message(millis: 1_700_000_000_000, value: "S:Old Name")
        let later = message(millis: 1_700_000_000_001, value: "S:New Name")

        let (orderedDb, orderedPath) = try makeDatabase()
        try orderedDb.applyMessages([earlier, later])

        let (reversedDb, reversedPath) = try makeDatabase()
        try reversedDb.applyMessages([later, earlier])

        #expect(try accountName(path: orderedPath, id: "acct-1") == "New Name")
        #expect(try accountName(path: reversedPath, id: "acct-1") == "New Name")
    }
}
