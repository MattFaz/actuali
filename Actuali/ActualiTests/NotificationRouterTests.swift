import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct NotificationRouterTests {

    // MARK: - Route parsing (tapped notification -> route)

    @Test func singleTransactionIdRoutesToEditor() {
        let route = NotificationRouter.route(
            categoryIdentifier: NewTransactionNotifier.categoryIdentifier,
            userInfo: [NewTransactionNotifier.transactionIdsKey: ["t1"]])

        #expect(route == .editTransaction(id: "t1"))
    }

    @Test func multipleTransactionIdsRouteToUncategorized() {
        let route = NotificationRouter.route(
            categoryIdentifier: NewTransactionNotifier.categoryIdentifier,
            userInfo: [NewTransactionNotifier.transactionIdsKey: ["t1", "t2"]])

        #expect(route == .uncategorized)
    }

    @Test func missingIdsRouteToUncategorized() {
        let route = NotificationRouter.route(
            categoryIdentifier: NewTransactionNotifier.categoryIdentifier,
            userInfo: [:])

        #expect(route == .uncategorized)
    }

    @Test func unrelatedNotificationCategoryIsIgnored() {
        let route = NotificationRouter.route(
            categoryIdentifier: "SOMETHING_ELSE",
            userInfo: [NewTransactionNotifier.transactionIdsKey: ["t1"]])

        #expect(route == nil)
    }

    // MARK: - Destination resolution (route -> screen)

    private func makeStore() throws -> BudgetStore {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    isParent INTEGER DEFAULT 0,
                    isChild INTEGER DEFAULT 0,
                    acct TEXT,
                    category TEXT,
                    amount INTEGER,
                    description TEXT,
                    notes TEXT,
                    date INTEGER,
                    imported_description TEXT,
                    transferred_id TEXT,
                    sort_order REAL,
                    tombstone INTEGER DEFAULT 0,
                    cleared INTEGER DEFAULT 0,
                    reconciled INTEGER DEFAULT 0,
                    parent_id TEXT
                )
                """)
            try db.execute(sql: "CREATE TABLE accounts (id TEXT PRIMARY KEY, name TEXT, tombstone INTEGER DEFAULT 0)")
            try db.execute(sql: "CREATE TABLE payees (id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, tombstone INTEGER DEFAULT 0)")
            try db.execute(sql: "CREATE TABLE payee_mapping (id TEXT PRIMARY KEY, targetId TEXT)")
            try db.execute(sql: "CREATE TABLE categories (id TEXT PRIMARY KEY, name TEXT, tombstone INTEGER DEFAULT 0)")
            try db.execute(sql: "CREATE TABLE category_mapping (id TEXT PRIMARY KEY, transferId TEXT)")
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
            try db.execute(sql: "INSERT INTO transactions (id, acct, amount, date) VALUES ('t1', 'acct1', -1250, 20260707)")
        }
        let database = try BudgetDatabase(path: tempURL)
        let store = BudgetStore.previewInstance()
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        store.configureForTesting(database: database, syncClient: syncClient)
        return store
    }

    @Test func resolvesEditorForExistingTransaction() async throws {
        let store = try makeStore()

        let destination = await NotificationRouter.destination(
            for: .editTransaction(id: "t1"), in: store)

        guard case .editor(let transaction) = destination else {
            Issue.record("Expected .editor, got \(destination)")
            return
        }
        #expect(transaction.id == "t1")
    }

    @Test func staleTransactionIdFallsBackToUncategorized() async throws {
        let store = try makeStore()

        let destination = await NotificationRouter.destination(
            for: .editTransaction(id: "gone"), in: store)

        #expect(destination == .uncategorized)
    }

    @Test func uncategorizedRouteResolvesDirectly() async throws {
        let store = try makeStore()

        let destination = await NotificationRouter.destination(
            for: .uncategorized, in: store)

        #expect(destination == .uncategorized)
    }
}
