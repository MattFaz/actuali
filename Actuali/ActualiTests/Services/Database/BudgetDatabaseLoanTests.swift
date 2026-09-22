import Foundation
import GRDB
import Testing
@testable import Actuali

/// Pins `fetchLoanConfigs()` against the SQLite `preferences` table. Loans share
/// their decode path with credit cards, so the prefixes staying apart is part of
/// what these cover.
@MainActor
struct BudgetDatabaseLoanTests {
    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT)")
        }
        let database = try BudgetDatabase(path: tempURL)
        return (database, tempURL)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func encoded(_ value: some Encodable) throws -> String {
        try String(decoding: JSONEncoder().encode(value), as: UTF8.self)
    }

    private func insert(_ db: BudgetDatabase, id: String, json: String) async throws {
        try await db.dbQueueForTesting.write { conn in
            try conn.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, ?)",
                arguments: [id, json]
            )
        }
    }

    @Test func fetchLoanConfigsReturnsDecodedConfigs() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        let car = LoanConfig(
            originalBalance: 2_200_000,
            annualRatePercent: 6,
            minimumPayment: 36500,
            escrowOrFees: nil
        )
        let house = LoanConfig(
            originalBalance: 45_000_000,
            annualRatePercent: 4.125,
            minimumPayment: 210_000,
            escrowOrFees: 40000
        )

        try await insert(db, id: "actuali:loan:acct_car", json: encoded(car))
        try await insert(db, id: "actuali:loan:acct_house", json: encoded(house))
        try await insert(db, id: "defaultCurrencyCode", json: "USD")

        let configs = try await db.fetchLoanConfigs()
        #expect(configs.count == 2)
        #expect(configs["acct_car"] == car)
        #expect(configs["acct_house"] == house)
    }

    @Test func fetchLoanConfigsIgnoresNullEmptyAndInvalidRows() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, NULL)",
                arguments: ["actuali:loan:acct_null"]
            )
            try conn.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, '')",
                arguments: ["actuali:loan:acct_empty"]
            )
            try conn.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, ?)",
                arguments: ["actuali:loan:acct_corrupt", "{invalid_json}"]
            )
        }

        let configs = try await db.fetchLoanConfigs()
        #expect(configs.isEmpty)
    }

    /// The two config types share one decode helper, so a loan must never show
    /// up as a card or the reverse.
    @Test func loanAndCreditCardConfigsDoNotBleedIntoEachOther() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        let loan = LoanConfig(
            originalBalance: 2_200_000,
            annualRatePercent: 6,
            minimumPayment: 36500,
            escrowOrFees: nil
        )
        let card = CreditCardConfig(statementDay: 18, dueOffsetDays: 25, limit: 500_000)

        try await insert(db, id: "actuali:loan:acct_shared", json: encoded(loan))
        try await insert(db, id: "actuali:credit_card:acct_shared", json: encoded(card))

        let loans = try await db.fetchLoanConfigs()
        let cards = try await db.fetchCreditCardConfigs()

        #expect(loans.count == 1)
        #expect(loans["acct_shared"] == loan)
        #expect(cards.count == 1)
        #expect(cards["acct_shared"] == card)
    }

    @Test func loanPreferenceKeyIsNamespaced() {
        #expect(BudgetDatabase.loanPreferenceKey(for: "acct_1") == "actuali:loan:acct_1")
    }
}
