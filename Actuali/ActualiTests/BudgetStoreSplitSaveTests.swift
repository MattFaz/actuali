import Foundation
import GRDB
import Testing
@testable import Actuali

/// End-to-end split behavior through `BudgetStore` (GH #47): creating a
/// split from the form, editing a split parent (amount + line
/// reconciliation), the conversion guards, and the delete cascade to
/// children.
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
            // Children inherit the parent's payee (Actual's makeChild semantics)
            #expect(child["description"] == createdPayee.id)
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

    @Test func splitLinePayeeOverrideCreatesDistinctChildPayee() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

        var overridden = BudgetStore.SplitLineForm(categoryId: "cat-med", amount: "6.00")
        overridden.payeeName = "Pharmacy"
        try await store.saveTransaction(form(
            type: .expense, amount: "10.00", payeeName: "Costco",
            splits: [overridden, .init(categoryId: "cat-food", amount: "4.00")]
        ))

        let all = try rows(path: path)
        #expect(all.count == 3)
        let costco = try #require(store.payees.first { $0.name == "Costco" })
        let pharmacy = try #require(store.payees.first { $0.name == "Pharmacy" })
        #expect(all[0]["description"] == costco.id)   // parent
        #expect(all[1]["description"] == pharmacy.id) // overridden line
        #expect(all[2]["description"] == costco.id)   // inherits parent
    }

    @Test func editingParentPayeeCascadesToChildrenThatMatchedIt() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

        try await database.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO payees (id, name) VALUES
                    ('p-old', 'Old Grocer'),
                    ('p-other', 'Pharmacy');
                INSERT INTO payee_mapping (id, targetId) VALUES
                    ('p-old', 'p-old'),
                    ('p-other', 'p-other');

                INSERT INTO transactions (id, acct, category, description, amount, date, isParent, isChild, parent_id, sort_order) VALUES
                    ('parent',    'acct-1', NULL,       'p-old',   -1000, 20260601, 1, 0, NULL,     10),
                    ('c-match',   'acct-1', 'cat-food', 'p-old',    -600, 20260601, 0, 1, 'parent',  9),
                    ('c-override','acct-1', 'cat-med',  'p-other',  -400, 20260601, 0, 1, 'parent',  8);
            """)
        }
        store.payees = [
            Payee(id: "p-old", name: "Old Grocer", transferAccountId: nil, tombstone: false),
            Payee(id: "p-other", name: "Pharmacy", transferAccountId: nil, tombstone: false)
        ]

        let original = Transaction(
            id: "parent", accountId: "acct-1", date: 20260601, amount: -1000,
            payeeId: "p-old", payeeName: "Old Grocer", categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: true, parentId: nil, tombstone: false, sortOrder: 10,
            importedPayee: nil
        )

        var edit = form(amount: "10.00", payeeName: "New Grocer")
        edit.date = Transaction.date(fromYYYYMMDD: 20260601)
        try await store.saveTransaction(edit, editing: original)

        let newPayee = try #require(store.payees.first { $0.name == "New Grocer" })
        let all = try rows(path: path)
        let payees = Dictionary(uniqueKeysWithValues: all.map { ($0["id"] as String, $0["description"] as String?) })
        // Parent and the child that shared its payee follow the edit; the
        // deliberately different child keeps its own payee (Actual semantics).
        #expect(payees == [
            "parent": newPayee.id,
            "c-match": newPayee.id,
            "c-override": "p-other"
        ])
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

    @Test func editingASplitParentUpdatesAmountAndReconcilesChildren() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

        try await database.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO transactions (id, acct, category, description, amount, date, isParent, isChild, parent_id, sort_order) VALUES
                    ('parent', 'acct-1', NULL,       NULL, -1000, 20260601, 1, 0, NULL,     10),
                    ('c-1',    'acct-1', 'cat-food', NULL,  -600, 20260601, 0, 1, 'parent',  9),
                    ('c-2',    'acct-1', 'cat-fun',  NULL,  -400, 20260601, 0, 1, 'parent',  8);
            """)
        }

        let original = Transaction(
            id: "parent", accountId: "acct-1", date: 20260601, amount: -1000,
            payeeId: nil, payeeName: nil, categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: true, parentId: nil, tombstone: false, sortOrder: 10,
            importedPayee: nil
        )

        // Total 10.00 → 12.00; c-1 re-amounted/re-categorized with a note,
        // c-2 dropped, and a new 7.00 line added.
        var edit = form(amount: "12.00", payeeName: "Market", splits: [
            .init(childId: "c-1", categoryId: "cat-med", amount: "5.00", notes: "updated"),
            .init(categoryId: "cat-new", amount: "7.00")
        ])
        edit.date = Transaction.date(fromYYYYMMDD: 20260601)
        try await store.saveTransaction(edit, editing: original)

        let all = try rows(path: path)
        #expect(all.count == 4)
        let byId = Dictionary(uniqueKeysWithValues: all.map { ($0["id"] as String, $0) })

        let parent = try #require(byId["parent"])
        #expect(parent["amount"] == -1200)
        #expect(parent["category"] == nil)
        let market = try #require(store.payees.first { $0.name == "Market" })
        #expect(parent["description"] == market.id)

        let updated = try #require(byId["c-1"])
        #expect(updated["amount"] == -500)
        #expect(updated["category"] == "cat-med")
        #expect(updated["notes"] == "updated")
        // The line inherited the parent's (new) payee
        #expect(updated["description"] == market.id)
        #expect(updated["tombstone"] == 0)

        let removed = try #require(byId["c-2"])
        #expect(removed["tombstone"] == 1)

        let added = try #require(all.first { !["parent", "c-1", "c-2"].contains($0["id"] as String) })
        #expect(added["isChild"] == 1)
        #expect(added["isParent"] == 0)
        #expect(added["parent_id"] == "parent")
        #expect(added["amount"] == -700)
        #expect(added["category"] == "cat-new")
        #expect(added["description"] == market.id)
        // New lines slot in below every existing child
        let addedSort: Double = try #require(added["sort_order"])
        #expect(addedSort < 8)

        // Every touched row produced CRDT messages (parent, c-1, c-2, new child)
        let queue = try DatabaseQueue(path: path.path)
        let messageRows = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT row) FROM messages_crdt WHERE dataset = 'transactions'") ?? -1
        }
        #expect(messageRows == 4)
    }

    @Test func editingASplitParentKeepsChildPayeeOverrides() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let store = try await makeStore(database: database)

        try await database.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO payees (id, name) VALUES ('p-main', 'Costco'), ('p-other', 'Pharmacy');
                INSERT INTO payee_mapping (id, targetId) VALUES ('p-main', 'p-main'), ('p-other', 'p-other');
                INSERT INTO transactions (id, acct, category, description, amount, date, isParent, isChild, parent_id, sort_order) VALUES
                    ('parent', 'acct-1', NULL,       'p-main',  -1000, 20260601, 1, 0, NULL,     10),
                    ('c-1',    'acct-1', 'cat-food', 'p-main',   -600, 20260601, 0, 1, 'parent',  9),
                    ('c-2',    'acct-1', 'cat-med',  'p-other',  -400, 20260601, 0, 1, 'parent',  8);
            """)
        }
        store.payees = [
            Payee(id: "p-main", name: "Costco", transferAccountId: nil, tombstone: false),
            Payee(id: "p-other", name: "Pharmacy", transferAccountId: nil, tombstone: false)
        ]

        let original = Transaction(
            id: "parent", accountId: "acct-1", date: 20260601, amount: -1000,
            payeeId: "p-main", payeeName: "Costco", categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: true, parentId: nil, tombstone: false, sortOrder: 10,
            importedPayee: nil
        )

        // The edit sheet loads c-1 (payee == parent's) as "inherit" and c-2's
        // override verbatim; the parent payee changes to New Grocer.
        var overrideLine = BudgetStore.SplitLineForm(childId: "c-2", categoryId: "cat-med", amount: "4.00")
        overrideLine.payeeName = "Pharmacy"
        var edit = form(amount: "10.00", payeeName: "New Grocer", splits: [
            .init(childId: "c-1", categoryId: "cat-food", amount: "6.00"),
            overrideLine
        ])
        edit.date = Transaction.date(fromYYYYMMDD: 20260601)
        try await store.saveTransaction(edit, editing: original)

        let newPayee = try #require(store.payees.first { $0.name == "New Grocer" })
        let all = try rows(path: path)
        let payees = Dictionary(uniqueKeysWithValues: all.map { ($0["id"] as String, $0["description"] as String?) })
        #expect(payees == [
            "parent": newPayee.id,
            "c-1": newPayee.id,
            "c-2": "p-other"
        ])
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
