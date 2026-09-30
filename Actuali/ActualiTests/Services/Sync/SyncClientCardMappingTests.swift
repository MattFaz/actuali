import Foundation
import GRDB
import Testing
@testable import Actuali

/// Pins `setCardAccountMappings()` on `SyncClient`.
@MainActor
struct SyncClientCardMappingTests {
    private func makeDatabase() async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase(TestSchema.preferences, TestSchema.messagesCrdt)
    }

    private func makeSyncClient(
        database: BudgetDatabase,
        nodeId: String = "89e0e8e90b203f9e"
    ) async throws -> SyncClient {
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: nodeId)
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        return syncClient
    }

    @Test func concurrentMappingsUseIndependentCRDTRows() async throws {
        let (firstDatabase, firstPath) = try await makeDatabase()
        let (secondDatabase, secondPath) = try await makeDatabase()
        let (mergedDatabase, mergedPath) = try await makeDatabase()
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
            firstDatabase.getMessagesSince("") + secondDatabase.getMessagesSince("")
        )
        let fetched = try await mergedDatabase.fetchCardAccountMappings()
        #expect(fetched["1234"] == "acct_chase")
        #expect(fetched["HSBC"] == "acct_hsbc")

        let rows = try firstDatabase.getMessagesSince("") + secondDatabase.getMessagesSince("")
        #expect(Set(rows.map(\.row)) == Set([
            BudgetDatabase.cardMappingPreferenceKey(for: "1234"),
            BudgetDatabase.cardMappingPreferenceKey(for: "HSBC"),
        ]))
    }

    @Test func emptyMappingsClearsRowAndEmitsNullMessage() async throws {
        let (database, path) = try await makeDatabase()
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
