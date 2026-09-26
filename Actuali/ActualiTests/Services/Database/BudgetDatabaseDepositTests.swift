import Foundation
import GRDB
import Testing
@testable import Actuali

/// Pins `fetchDepositConfigs()` against the SQLite `preferences` table.
/// Deposits are the third config type sharing one decode helper with loans and
/// credit cards, so the prefixes staying apart is part of what these cover.
@MainActor
struct BudgetDatabaseDepositTests {
    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT)")
        }
        return try (BudgetDatabase(path: tempURL), tempURL)
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

    private let fixed = DepositConfig(
        kind: .fixed,
        amount: 10_000_000,
        annualRatePercent: 7,
        compounding: .quarterly,
        openedOn: DayDate(year: 2026, month: 1, day: 15),
        termMonths: 60
    )

    private let recurring = DepositConfig(
        kind: .recurring,
        amount: 500_000,
        annualRatePercent: 6.75,
        compounding: .monthly,
        openedOn: DayDate(year: 2026, month: 4, day: 1),
        termMonths: 24
    )

    @Test func fetchDepositConfigsReturnsDecodedConfigs() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await insert(db, id: "actuali:deposit:acct_fd", json: encoded(fixed))
        try await insert(db, id: "actuali:deposit:acct_rd", json: encoded(recurring))
        try await insert(db, id: "defaultCurrencyCode", json: "INR")

        let configs = try await db.fetchDepositConfigs()
        #expect(configs.count == 2)
        #expect(configs["acct_fd"] == fixed)
        #expect(configs["acct_rd"] == recurring)
    }

    @Test func fetchDepositConfigsIgnoresNullEmptyAndInvalidRows() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, NULL)",
                arguments: ["actuali:deposit:acct_null"]
            )
            try conn.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, '')",
                arguments: ["actuali:deposit:acct_empty"]
            )
            try conn.execute(
                sql: "INSERT INTO preferences (id, value) VALUES (?, ?)",
                arguments: ["actuali:deposit:acct_corrupt", "{invalid_json}"]
            )
        }

        let configs = try await db.fetchDepositConfigs()
        #expect(configs.isEmpty)
    }

    /// A deposit whose opening date didn't survive is skipped rather than
    /// failing the whole load — one bad row can't cost the others.
    @Test func aDepositWithAnUnusableOpeningDayIsSkippedNotFatal() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        try await insert(db, id: "actuali:deposit:acct_good", json: encoded(fixed))
        try await insert(
            db, id: "actuali:deposit:acct_bad",
            json: #"{"kind":"fixed","amount":1,"annualRatePercent":7,"compounding":4,"openedOn":0,"termMonths":12}"#
        )

        let configs = try await db.fetchDepositConfigs()
        #expect(configs.count == 1)
        #expect(configs["acct_good"] == fixed)
    }

    /// All three config types share one decode helper, so none may show up as
    /// another.
    @Test func depositLoanAndCardConfigsDoNotBleedIntoEachOther() async throws {
        let (db, url) = try makeDatabase()
        defer { cleanup(url) }

        let loan = LoanConfig(
            originalBalance: 2_200_000, annualRatePercent: 6,
            minimumPayment: 36500, escrowOrFees: nil
        )
        let card = CreditCardConfig(statementDay: 18, dueOffsetDays: 25, limit: 500_000)

        try await insert(db, id: "actuali:deposit:acct_shared", json: encoded(fixed))
        try await insert(db, id: "actuali:loan:acct_shared", json: encoded(loan))
        try await insert(db, id: "actuali:credit_card:acct_shared", json: encoded(card))

        let deposits = try await db.fetchDepositConfigs()
        let loans = try await db.fetchLoanConfigs()
        let cards = try await db.fetchCreditCardConfigs()

        #expect(deposits == ["acct_shared": fixed])
        #expect(loans == ["acct_shared": loan])
        #expect(cards == ["acct_shared": card])
    }

    @Test func depositPreferenceKeyIsNamespaced() {
        #expect(BudgetDatabase.depositPreferenceKey(for: "acct_1") == "actuali:deposit:acct_1")
    }
}
