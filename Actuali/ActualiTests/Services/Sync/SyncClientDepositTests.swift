import Foundation
import GRDB
import Testing
@testable import Actuali

/// Pins `setDepositConfig()` on `SyncClient`: the config lands in the local
/// `preferences` table and emits a CRDT message on dataset "preferences",
/// row "actuali:deposit:<accountId>", column "value", so it converges like any
/// other synced preference.
@MainActor
struct SyncClientDepositTests {
    private func makeDatabase() async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase(TestSchema.preferences, TestSchema.messagesCrdt)
    }

    private let config = DepositConfig(
        kind: .recurring,
        amount: 500_000,
        annualRatePercent: 7,
        compounding: .quarterly,
        openedOn: DayDate(year: 2026, month: 1, day: 15),
        termMonths: 24
    )

    @Test func writesPreferencesRowAndEmitsCRDTMessage() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }

        let client = try await makeTestSyncClient(database: database)
        try await client.setDepositConfig(accountId: "acct_rd", config: config)

        let configs = try await database.fetchDepositConfigs()
        let stored = try #require(configs["acct_rd"])
        #expect(stored == config)

        let messages = try messageRows(path: path)
        #expect(messages.count == 1)
        let message = try #require(messages.first)
        #expect(message["dataset"] == "preferences")
        #expect(message["row"] == "actuali:deposit:acct_rd")
        #expect(message["column"] == "value")
    }

    @Test func clearingConfigSetsNullInPreferencesAndEmitsNullCRDTMessage() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }

        let client = try await makeTestSyncClient(database: database)
        try await client.setDepositConfig(accountId: "acct_rd", config: config)
        try await client.setDepositConfig(accountId: "acct_rd", config: nil)

        let configs = try await database.fetchDepositConfigs()
        #expect(configs["acct_rd"] == nil)

        let messages = try messageRows(path: path)
        #expect(messages.count == 2)
        #expect(messages[1]["row"] == "actuali:deposit:acct_rd")
        #expect(messages[1]["value"] == "0:") // Null CRDT value representation
    }

    /// The opening day survives the round trip through Actual's preferences
    /// table, which is the part the `YYYYMMDD` wire format exists to protect.
    @Test func theOpeningDaySurvivesTheRoundTrip() async throws {
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }

        let client = try await makeTestSyncClient(database: database)
        try await client.setDepositConfig(accountId: "acct_rd", config: config)

        let configs = try await database.fetchDepositConfigs()
        let stored = try #require(configs["acct_rd"])
        #expect(stored.openedOn == DayDate(year: 2026, month: 1, day: 15))
        #expect(stored.maturityDate == DayDate(year: 2028, month: 1, day: 15))
    }
}
