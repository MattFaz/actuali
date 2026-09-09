import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreCreditCardStatementDueTests {

    private func makeStore() throws -> (BudgetStore, BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-due-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
                CREATE TABLE messages_crdt (
                    id INTEGER PRIMARY KEY,
                    timestamp TEXT NOT NULL UNIQUE,
                    dataset TEXT NOT NULL,
                    row TEXT NOT NULL,
                    column TEXT NOT NULL,
                    value BLOB NOT NULL
                );
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    offbudget INTEGER DEFAULT 0,
                    closed INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0
                );
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    isParent INTEGER DEFAULT 0,
                    isChild INTEGER DEFAULT 0,
                    acct TEXT,
                    category TEXT,
                    description TEXT,
                    amount INTEGER,
                    notes TEXT,
                    date INTEGER,
                    imported_description TEXT,
                    schedule TEXT,
                    transferred_id TEXT,
                    cleared INTEGER DEFAULT 0,
                    reconciled INTEGER DEFAULT 0,
                    sort_order REAL,
                    tombstone INTEGER DEFAULT 0,
                    parent_id TEXT
                );
            """)
        }
        let database = try BudgetDatabase(path: tempURL)
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        let store = BudgetStore.previewInstance()
        store.currentBudgetId = "test-budget"
        store.configureForTesting(database: database, syncClient: syncClient)
        return (store, database, tempURL)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test func loadCreditCardStatementDuesUsesPendingStatement() async throws {
        let (store, database, url) = try makeStore()
        defer { cleanup(url) }

        // Configure active credit card cycle closing on the 15th
        let openCard = Account(id: "card_open", name: "Open Card", type: .credit, offBudget: false, closed: false, sortOrder: 0, balance: -20000)
        let closedCard = Account(id: "card_closed", name: "Closed Card", type: .credit, offBudget: false, closed: true, sortOrder: 1, balance: -10000)
        store.accounts = [openCard, closedCard]

        store.creditCardConfigs["card_open"] = CreditCardConfig(statementDay: 15, dueOffsetDays: 15, limit: nil)
        store.creditCardConfigs["card_closed"] = CreditCardConfig(statementDay: 15, dueOffsetDays: 15, limit: nil)

        let cycle = store.activeCreditCardCycle(for: "card_open")!
        let pending = cycle.upcomingStatementDate()

        // Insert a charge on pending statement closing, and a payment after
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
                INSERT INTO transactions (id, acct, amount, date, tombstone, isParent, isChild, parent_id) VALUES
                    ('tx_charge', 'card_open', -50000, ?, 0, 0, 0, NULL),
                    ('tx_payment', 'card_open', 50000, ?, 0, 0, 0, NULL);
            """, arguments: [pending.yyyymmdd, pending.adding(days: 1).yyyymmdd])
        }

        await store.loadCreditCardStatementDues()

        // Open card should reflect the paid statement
        let openDue = store.creditCardStatementDues["card_open"]
        #expect(openDue != nil)
        #expect(openDue?.statementBalance == 50000)
        #expect(openDue?.paymentsSince == 50000)
        #expect(openDue?.remainingDue == 0)
        #expect(openDue?.isPaid == true)

        // Closed card should be skipped
        #expect(store.creditCardStatementDues["card_closed"] == nil)
    }

    @Test func loadCreditCardStatementDuesClearsOnMissingDatabase() async throws {
        let store = BudgetStore.previewInstance()
        store.creditCardStatementDues = [
            "card1": CreditCardCycle.StatementDue(statementBalance: 1000, paymentsSince: 0, remainingDue: 1000)
        ]
        await store.loadCreditCardStatementDues()
        #expect(store.creditCardStatementDues.isEmpty)
    }
}
