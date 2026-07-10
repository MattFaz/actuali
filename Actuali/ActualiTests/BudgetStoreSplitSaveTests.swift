import Foundation
import GRDB
import Testing
@testable import Actuali

/// End-to-end split behavior through `BudgetStore` (GH #47): creating a
/// split from the form, the guards around editing split parents, and the
/// delete cascade to children.
@MainActor
struct BudgetStoreSplitSaveTests {

    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    offbudget INTEGER DEFAULT 0,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE payees (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    transfer_acct TEXT,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE payee_mapping (
                    id TEXT PRIMARY KEY,
                    targetId TEXT
                );

                CREATE TABLE categories (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE category_mapping (
                    id TEXT PRIMARY KEY,
                    transferId TEXT
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
                    transferred_id TEXT,
                    cleared INTEGER DEFAULT 0,
                    reconciled INTEGER DEFAULT 0,
                    sort_order REAL,
                    parent_id TEXT,
                    tombstone INTEGER DEFAULT 0
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

    private func makeStore(database: BudgetDatabase) async throws -> BudgetStore {
        let store = BudgetStore.previewInstance()
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        store.configureForTesting(database: database, syncClient: syncClient)
        return store
    }

    private func rows(path: URL, orderBy: String = "sort_order DESC") throws -> [Row] {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM transactions ORDER BY \(orderBy)")
        }
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func form(
        type: TransactionType = .expense,
        amount: String,
        payeeName: String = "",
        splits: [BudgetStore.SplitLineForm] = []
    ) -> BudgetStore.TransactionForm {
        BudgetStore.TransactionForm(
            accountId: "acct-1",
            type: type,
            amount: amount,
            payeeName: payeeName,
            transferToAccountId: nil,
            categoryId: nil,
            notes: "",
            date: Date(),
            cleared: false,
            splits: splits
        )
    }

    @Test func savingASplitPersistsParentAndChildren() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

        try await store.saveTransaction(form(
            type: .expense, amount: "10.00", payeeName: "Trader Joe's",
            splits: [
                .init(categoryId: "cat-food", amount: "6.00"),
                .init(categoryId: "cat-fun", amount: "4.00", notes: "treat")
            ]
        ))

        let all = try rows(path: path)
        #expect(all.count == 3)

        let parent = all[0]
        #expect(parent["isParent"] == 1)
        #expect(parent["isChild"] == 0)
        #expect(parent["amount"] == -1000)
        // Split parents never carry a category; children do.
        #expect(parent["category"] == nil)
        #expect(parent["imported_description"] == "Trader Joe's")
        let createdPayee = try #require(store.payees.first { $0.name == "Trader Joe's" })
        #expect(parent["description"] == createdPayee.id)

        let first = all[1], second = all[2]
        for child in [first, second] {
            #expect(child["isChild"] == 1)
            #expect(child["isParent"] == 0)
            #expect(child["parent_id"] == (parent["id"] as String?))
            // The payee lives on the parent
            #expect(child["description"] == nil)
        }
        // Children keep the entered order via descending sort_order
        #expect(first["amount"] == -600)
        #expect(first["category"] == "cat-food")
        #expect(second["amount"] == -400)
        #expect(second["category"] == "cat-fun")
        #expect(second["notes"] == "treat")
        let parentSort: Double = try #require(parent["sort_order"])
        let firstSort: Double = try #require(first["sort_order"])
        let secondSort: Double = try #require(second["sort_order"])
        #expect(firstSort < parentSort)
        #expect(secondSort < firstSort)

        // CRDT messages were written for all three rows
        let queue = try DatabaseQueue(path: path.path)
        let messageRows = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT row) FROM messages_crdt WHERE dataset = 'transactions'") ?? -1
        }
        #expect(messageRows == 3)
    }

    @Test func editingIntoASplitIsRejected() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

        let original = Transaction(
            id: "tx-1", accountId: "acct-1", date: 20260610, amount: -500,
            payeeId: nil, payeeName: nil, categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: false, parentId: nil, tombstone: false, sortOrder: nil,
            importedPayee: nil
        )
        try database.insertTransaction(original)

        let edit = form(amount: "5.00", splits: [
            .init(categoryId: "cat-food", amount: "3.00"),
            .init(categoryId: "cat-fun", amount: "2.00")
        ])
        await #expect(throws: BudgetStoreError.cannotConvertToSplit) {
            try await store.saveTransaction(edit, editing: original)
        }

        let all = try rows(path: path)
        #expect(all.count == 1)
        #expect(all[0]["amount"] == -500)
    }

    @Test func editingASplitParentProtectsAmountAndCategoryAndCascadesSharedFields() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

        try await database.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, category, description, amount, date, isParent, isChild, parent_id, sort_order, cleared) VALUES
                    ('parent', 'acct-1', NULL,       'p-1', -1000, 20260601, 1, 0, NULL,     10, 0),
                    ('c-1',    'acct-1', 'cat-food', NULL,   -600, 20260601, 0, 1, 'parent',  9, 0),
                    ('c-2',    'acct-1', 'cat-fun',  NULL,   -400, 20260601, 0, 1, 'parent',  8, 0);
            """)
        }

        let original = Transaction(
            id: "parent", accountId: "acct-1", date: 20260601, amount: -1000,
            payeeId: "p-1", payeeName: nil, categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: true, parentId: nil, tombstone: false, sortOrder: 10,
            importedPayee: nil
        )

        // The form arrives with a category and a diverged amount (the UI
        // presents both read-only for parents, but the store must not trust
        // that); date/cleared/notes edits are legitimate.
        var edit = form(amount: "55.55")
        edit.categoryId = "cat-food"
        edit.notes = "edited"
        edit.cleared = true
        edit.date = Transaction.date(fromYYYYMMDD: 20260715)
        try await store.saveTransaction(edit, editing: original)

        let all = try rows(path: path)
        #expect(all.count == 3)
        let parent = all[0]
        // Amount stays the children's sum; category stays NULL
        #expect(parent["amount"] == -1000)
        #expect(parent["category"] == nil)
        #expect(parent["notes"] == "edited")
        #expect(parent["date"] == 20260715)
        #expect(parent["cleared"] == 1)
        // Shared fields cascade to the children; their own splits are untouched
        for child in [all[1], all[2]] {
            #expect(child["date"] == 20260715)
            #expect(child["cleared"] == 1)
        }
        #expect(all[1]["amount"] == -600)
        #expect(all[1]["category"] == "cat-food")
        #expect(all[2]["amount"] == -400)
        #expect(all[2]["category"] == "cat-fun")
    }

    @Test func deletingASplitParentTombstonesItsChildren() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

        try await database.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, category, amount, date, isParent, isChild, parent_id, sort_order) VALUES
                    ('parent',   'acct-1', NULL,       -1000, 20260601, 1, 0, NULL,     10),
                    ('c-1',      'acct-1', 'cat-food',  -600, 20260601, 0, 1, 'parent',  9),
                    ('c-2',      'acct-1', 'cat-fun',   -400, 20260601, 0, 1, 'parent',  8),
                    ('bystander','acct-1', 'cat-food',  -200, 20260601, 0, 0, NULL,      7);
            """)
        }

        let parent = Transaction(
            id: "parent", accountId: "acct-1", date: 20260601, amount: -1000,
            payeeId: nil, payeeName: nil, categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: true, parentId: nil, tombstone: false, sortOrder: 10,
            importedPayee: nil
        )
        await store.deleteTransaction(parent)

        let all = try rows(path: path)
        let tombstones = Dictionary(uniqueKeysWithValues: all.map { ($0["id"] as String, $0["tombstone"] as Int) })
        #expect(tombstones == ["parent": 1, "c-1": 1, "c-2": 1, "bystander": 0])
    }
}
