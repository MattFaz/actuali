import Foundation
import GRDB
import Testing
@testable import Actuali

/// Pins `setCardAccountMappings()` on `SyncClient`.
@MainActor
struct SyncClientCardMappingTests {

    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE preferences (
                    id TEXT PRIMARY KEY,
                    value TEXT
                );
                CREATE TABLE messages_crdt (
                    id INTEGER PRIMARY KEY,
                    timestamp TEXT NOT NULL UNIQUE,
                    dataset TEXT NOT NULL,
                    row TEXT NOT NULL,
                    column TEXT NOT NULL,
                    value BLOB NOT NULL
                );
                """)
        }
        return (try BudgetDatabase(path: tempURL), tempURL)
    }

    private func makeSyncClient(
        database: BudgetDatabase,
        nodeId: String = "89e0e8e90b203f9e"
    ) async throws -> SyncClient {
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: nodeId)
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        return syncClient
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func messageRows(path: URL) throws -> [Row] {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM messages_crdt ORDER BY timestamp")
        }
    }

    @Test func concurrentMappingsUseIndependentCRDTRows() async throws {
        let (firstDatabase, firstPath) = try makeDatabase()
        let (secondDatabase, secondPath) = try makeDatabase()
        let (mergedDatabase, mergedPath) = try makeDatabase()
        defer {
            cleanup(firstPath)
            cleanup(secondPath)
            cleanup(mergedPath)
        }

        let firstClient = try await makeSyncClient(database: firstDatabase)
        let secondClient = try await makeSyncClient(
            database: secondDatabase,
            nodeId: "89e0e8e90b203f9f"
        )
        try await firstClient.setCardAccountMappings(["1234": "acct_chase"], replacing: [:])
        try await secondClient.setCardAccountMappings(["HSBC": "acct_hsbc"], replacing: [:])

        try mergedDatabase.applyMessages(
            try firstDatabase.getMessagesSince("") + secondDatabase.getMessagesSince("")
        )
        let fetched = try await mergedDatabase.fetchCardAccountMappings()
        #expect(fetched["1234"] == "acct_chase")
        #expect(fetched["HSBC"] == "acct_hsbc")

        let rows = try firstDatabase.getMessagesSince("") + secondDatabase.getMessagesSince("")
        #expect(Set(rows.map(\.row)) == Set([
            BudgetDatabase.cardMappingPreferenceKey(for: "1234"),
            BudgetDatabase.cardMappingPreferenceKey(for: "HSBC")
        ]))
    }

    @Test func emptyMappingsClearsRowAndEmitsNullMessage() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }

        let client = try await makeSyncClient(database: database)

        // Write then clear
        try await client.setCardAccountMappings(["1234": "acct_chase"], replacing: [:])
        try await client.setCardAccountMappings([:], replacing: ["1234": "acct_chase"])

        let fetched = try await database.fetchCardAccountMappings()
        #expect(fetched.isEmpty)

        let messages = try messageRows(path: path)
        #expect(messages.count == 2)
        #expect(messages[1]["row"] == BudgetDatabase.cardMappingPreferenceKey(for: "1234"))
        #expect(messages[1]["column"] == "value")
        #expect(messages[1]["value"] == "0:") // Null CRDT value representation
    }
}
