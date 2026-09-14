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
        let (store, database, url) = try makeStore()
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
                newer.end.yyyymmdd
            ])
        }

        await store.loadCreditCardStatementDues(today: today)

        let dues = store.creditCardStatementDues["card"]
        #expect(dues?.count == 3)
        #expect(dues?.first { $0.dueDate == older.dueDate }?.remainingDue == 0)
        #expect(dues?.first { $0.dueDate == newer.dueDate }?.remainingDue == 30000)
    }

    @Test func loadCreditCardStatementDuesClearsOnMissingDatabase() async throws {
        let store = BudgetStore.previewInstance()
        store.creditCardStatementDues = [
            "card1": [CreditCardCycle.StatementDue(
                statementBalance: 1000,
                paymentsSince: 0,
                remainingDue: 1000,
                dueDate: .today()
            )]
        ]
        await store.loadCreditCardStatementDues()
        #expect(store.creditCardStatementDues.isEmpty)
    }
}
