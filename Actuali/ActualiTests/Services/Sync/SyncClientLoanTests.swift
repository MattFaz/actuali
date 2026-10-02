import Foundation
import GRDB
import Testing
@testable import Actuali

/// Pins `setLoanConfig()` on `SyncClient`: the config lands in the local
/// `preferences` table and emits a CRDT message on dataset "preferences",
/// row "actuali:loan:<accountId>", column "value", so it converges like any
/// other synced preference.
@MainActor
struct SyncClientLoanTests {
    private func makeDatabase() async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase(TestSchema.preferences, TestSchema.messagesCrdt)
    }

    private let config = LoanConfig(
        originalBalance: 2_200_000,
        annualRatePercent: 6,
        minimumPayment: 36500,
        escrowOrFees: 20000
    )

    @Test func writesPreferencesRowAndEmitsCRDTMessage() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }

        let client = try await makeTestSyncClient(database: database)
        try await client.setLoanConfig(accountId: "acct_car", config: config)

        let configs = try await database.fetchLoanConfigs()
        let stored = try #require(configs["acct_car"])
        #expect(stored == config)

        let messages = try messageRows(path: path)
        #expect(messages.count == 1)
        let message = try #require(messages.first)
        #expect(message["dataset"] == "preferences")
        #expect(message["row"] == "actuali:loan:acct_car")
        #expect(message["column"] == "value")
    }

    @Test func clearingConfigSetsNullInPreferencesAndEmitsNullCRDTMessage() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }

        let client = try await makeTestSyncClient(database: database)
        try await client.setLoanConfig(accountId: "acct_car", config: config)
        try await client.setLoanConfig(accountId: "acct_car", config: nil)

        let configs = try await database.fetchLoanConfigs()
        #expect(configs["acct_car"] == nil)

        let messages = try messageRows(path: path)
        #expect(messages.count == 2)
        #expect(messages[1]["row"] == "actuali:loan:acct_car")
        #expect(messages[1]["value"] == "0:") // Null CRDT value representation
    }
}
