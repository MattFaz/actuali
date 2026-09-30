import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreCreditCardStatementDueTests {
    /// Skips `SyncClient.configure`: the due-date paths never sync.
    private func makeStore() async throws -> (BudgetStore, BudgetDatabase, URL) {
        let (database, url) = try await makeTestDatabase(
            TestSchema.preferences, TestSchema.messagesCrdt, TestSchema.accounts, TestSchema.transactions
        )
        let store = BudgetStore.previewInstance()
        store.currentBudgetId = "test-budget"
        store.configureForTesting(
            database: database,
            syncClient: SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        )
        return (store, database, url)
    }

    @Test func loadCreditCardStatementDuesUsesPendingStatement() async throws {
        let (store, database, url) = try await makeStore()
        defer { cleanup(url) }

        // Configure active credit card cycle closing on the 15th
        let openCard = Account(id: "card_open", name: "Open Card", type: .credit, offBudget: false, closed: false, sortOrder: 0, balance: -20000)
        let closedCard = Account(id: "card_closed", name: "Closed Card", type: .credit, offBudget: false, closed: true, sortOrder: 1, balance: -10000)
        store.accounts = [openCard, closedCard]

        store.creditCardConfigs["card_open"] = CreditCardConfig(statementDay: 15, dueOffsetDays: 15, limit: nil)
        store.creditCardConfigs["card_closed"] = CreditCardConfig(statementDay: 15, dueOffsetDays: 15, limit: nil)

        let today = DayDate(year: 2026, month: 2, day: 20)
        let cycle = store.activeCreditCardCycle(for: "card_open")!
        let pending = cycle.upcomingStatementDate(for: today)

        // Insert a charge on pending statement closing, and a payment after
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
                INSERT INTO transactions (id, acct, amount, date, tombstone, isParent, isChild, parent_id) VALUES
                    ('tx_charge', 'card_open', -50000, ?, 0, 0, 0, NULL),
                    ('tx_payment', 'card_open', 50000, ?, 0, 0, 0, NULL);
            """, arguments: [pending.yyyymmdd, pending.adding(days: 1).yyyymmdd])
        }

        await store.loadCreditCardStatementDues(today: today)

        // Open card should reflect the paid statement
        let openDue = store.creditCardStatementDues["card_open"]?
            .first { $0.dueDate == cycle.upcomingDueDate(for: today) }
        #expect(openDue != nil)
        #expect(openDue?.statementBalance == 50000)
        #expect(openDue?.paymentsSince == 50000)
        #expect(openDue?.remainingDue == 0)
        #expect(openDue?.isPaid == true)

        // Closed card should be skipped
        #expect(store.creditCardStatementDues["card_closed"] == nil)
    }

    @Test func loadCreditCardStatementDuesKeepsOverlappingStatements() async throws {
        let (store, database, url) = try await makeStore()
        defer { cleanup(url) }

        let today = DayDate(year: 2026, month: 2, day: 20)
        let cycle = CreditCardCycle(statementDay: 15, paymentDue: .daysAfter(45))
        let pending = cycle.recentStatementCycles(today: today)
            .filter { today <= $0.dueDate }
            .reversed()
        #expect(pending.count == 2)
        let older = pending[pending.startIndex]
        let newer = pending[pending.index(after: pending.startIndex)]

        store.accounts = [Account(
            id: "card", name: "Card", type: .credit, offBudget: false,
            closed: false, sortOrder: 0, balance: -30000
        )]
        store.creditCardConfigs["card"] = CreditCardConfig(statementDay: 15, dueOffsetDays: 45, limit: nil)

        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
                INSERT INTO transactions (id, acct, amount, date, tombstone, isParent, isChild, parent_id) VALUES
                    ('older_charge', 'card', -50000, ?, 0, 0, 0, NULL),
                    ('older_payment', 'card', 50000, ?, 0, 0, 0, NULL),
                    ('newer_charge', 'card', -30000, ?, 0, 0, 0, NULL);
            """, arguments: [
                older.end.yyyymmdd,
                older.end.adding(days: 1).yyyymmdd,
                newer.end.yyyymmdd,
            ])
        }

        await store.loadCreditCardStatementDues(today: today)

        let dues = store.creditCardStatementDues["card"]
        #expect(dues?.count == 3)
        #expect(dues?.first { $0.dueDate == older.dueDate }?.remainingDue == 0)
        #expect(dues?.first { $0.dueDate == newer.dueDate }?.remainingDue == 30000)
    }

    @Test func loadCreditCardStatementDuesClearsOnMissingDatabase() async {
        let store = BudgetStore.previewInstance()
        store.creditCardStatementDues = [
            "card1": [CreditCardCycle.StatementDue(
                statementBalance: 1000,
                paymentsSince: 0,
                remainingDue: 1000,
                dueDate: .today()
            )],
        ]
        await store.loadCreditCardStatementDues()
        #expect(store.creditCardStatementDues.isEmpty)
    }
}
