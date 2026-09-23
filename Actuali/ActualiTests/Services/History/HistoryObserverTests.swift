import Foundation
import GRDB
import Testing
@testable import Actuali

/// History diffs every live row in the database. `store.transactions` only
/// triggers a diff: it holds just the newest page, so its contents here are
/// set to whatever that page would show and must never be read as changes.
@Suite(.serialized)
@MainActor
struct HistoryObserverTests {
    private struct Fixture {
        let store: BudgetStore
        let queue: DatabaseQueue
        let url: URL
        let budgetID: String
    }

    private func makeFixture(rows: [String]) async throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
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
                financial_id TEXT,
                transferred_id TEXT,
                sort_order REAL,
                tombstone INTEGER DEFAULT 0,
                cleared INTEGER DEFAULT 0,
                reconciled INTEGER DEFAULT 0,
                parent_id TEXT
            );
            CREATE TABLE accounts (id TEXT PRIMARY KEY, name TEXT, offbudget INTEGER DEFAULT 0, tombstone INTEGER DEFAULT 0);
            CREATE TABLE payees (id TEXT PRIMARY KEY, name TEXT, transfer_acct TEXT, tombstone INTEGER DEFAULT 0);
            CREATE TABLE payee_mapping (id TEXT PRIMARY KEY, targetId TEXT);
            CREATE TABLE categories (id TEXT PRIMARY KEY, name TEXT, tombstone INTEGER DEFAULT 0);
            CREATE TABLE category_mapping (id TEXT PRIMARY KEY, transferId TEXT);
            CREATE TABLE rules (id TEXT PRIMARY KEY, stage TEXT, conditions_op TEXT, conditions TEXT, actions TEXT, tombstone INTEGER DEFAULT 0);
            CREATE TABLE messages_crdt (
                id INTEGER PRIMARY KEY,
                timestamp TEXT NOT NULL UNIQUE,
                dataset TEXT NOT NULL,
                row TEXT NOT NULL,
                column TEXT NOT NULL,
                value BLOB NOT NULL
            );
            INSERT INTO accounts (id, name) VALUES ('account', 'Checking');
            INSERT INTO payees (id, name) VALUES ('payee', 'Groceries');
            INSERT INTO payee_mapping (id, targetId) VALUES ('payee', 'payee');
            """)
        }
        let database = try BudgetDatabase(path: url)
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        let store = BudgetStore.previewInstance()
        store.configureForTesting(database: database, syncClient: syncClient)
        let budgetID = "history-observer-\(UUID().uuidString)"
        store.currentBudgetId = budgetID
        let fixture = Fixture(store: store, queue: queue, url: url, budgetID: budgetID)
        for id in rows {
            try await insert(id, into: fixture)
        }
        return fixture
    }

    private func insert(_ id: String, date: Int = 20_260_906, into fixture: Fixture) async throws {
        try await fixture.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO transactions (id, acct, amount, description, date, sort_order)
                VALUES (?, 'account', -1000, 'payee', ?, 0)
                """,
                arguments: [id, date]
            )
        }
    }

    private func execute(_ sql: String, _ arguments: StatementArguments = [], in fixture: Fixture) async throws {
        try await fixture.queue.write { db in
            try db.execute(sql: sql, arguments: arguments)
        }
    }

    /// The page as the store would publish it: live rows from the database,
    /// limited to `ids`.
    private func page(_ ids: [String], in fixture: Fixture) async -> [Transaction] {
        let all = await fixture.store.fetchTransactions(limit: 1000)
        return ids.compactMap { id in all.first { $0.id == id } }
    }

    private func cleanUp(_ fixture: Fixture) {
        UserDefaults.standard.removeObject(forKey: "history.actions.\(fixture.budgetID)")
        HistoryStore.shared.clearLoadedActions()
        HistoryStore.finishUndoRecording()
        try? FileManager.default.removeItem(at: fixture.url)
    }

    @Test func payeeCategoryAndDateEditsProduceHistoryActions() async throws {
        let fixture = try await makeFixture(rows: ["edited"])
        defer { cleanUp(fixture) }
        let store = fixture.store
        let observer = HistoryObserver(store: store)
        await observer.drainForTesting()

        try await execute(
            "UPDATE transactions SET description = 'payee-2' WHERE id = 'edited'",
            in: fixture
        )
        store.transactions = await page(["edited"], in: fixture)
        await observer.drainForTesting()

        try await execute(
            "UPDATE transactions SET category = 'category-2' WHERE id = 'edited'",
            in: fixture
        )
        store.transactions = await page(["edited"], in: fixture)
        await observer.drainForTesting()

        try await execute(
            "UPDATE transactions SET date = 20260909 WHERE id = 'edited'",
            in: fixture
        )
        store.transactions = await page(["edited"], in: fixture)
        await observer.drainForTesting()

        #expect(HistoryStore.shared.actions.count == 3)
        #expect(HistoryStore.shared.actions[2].before.first?.payeeId == "payee")
        #expect(HistoryStore.shared.actions[2].after.first?.payeeId == "payee-2")
        #expect(HistoryStore.shared.actions[1].before.first?.categoryId == nil)
        #expect(HistoryStore.shared.actions[1].after.first?.categoryId == "category-2")
        #expect(HistoryStore.shared.actions[0].before.first?.date == 20_260_906)
        #expect(HistoryStore.shared.actions[0].after.first?.date == 20_260_909)
    }

    @Test func splitCreationProducesOneHistoryActionWithChildren() async throws {
        let fixture = try await makeFixture(rows: ["existing"])
        defer { cleanUp(fixture) }

        try await execute("""
        INSERT INTO transactions (
            id, isParent, isChild, acct, amount, description, date, sort_order, parent_id
        ) VALUES
            ('split-parent', 1, 0, 'account', -1000, 'payee', 20260906, 20, NULL),
            ('split-child-1', 0, 1, 'account', -600, 'payee', 20260906, 19, 'split-parent'),
            ('split-child-2', 0, 1, 'account', -400, 'payee', 20260906, 18, 'split-parent')
        """, in: fixture)

        let store = fixture.store
        store.transactions = await page(["existing"], in: fixture)
        let observer = HistoryObserver(store: store)
        await observer.drainForTesting()

        try await insert("later", date: 20_260_907, into: fixture)
        try await execute(
            "UPDATE transactions SET isParent = 1 WHERE id = 'later'",
            in: fixture
        )
        try await execute("""
        INSERT INTO transactions (
            id, isParent, isChild, acct, amount, description, date, sort_order, parent_id
        ) VALUES
            ('later-child-1', 0, 1, 'account', -700, 'payee', 20260907, 1, 'later'),
            ('later-child-2', 0, 1, 'account', -300, 'payee', 20260907, 0, 'later')
        """, in: fixture)

        store.transactions = await page(["later", "existing"], in: fixture)
        await observer.drainForTesting()

        #expect(HistoryStore.shared.actions.count == 1)
        let action = try #require(HistoryStore.shared.actions.first)
        #expect(action.kind == .created)
        #expect(action.after.map(\.id).contains("later"))
        #expect(action.after.map(\.id).contains("later-child-1"))
        #expect(action.after.map(\.id).contains("later-child-2"))
        #expect(action.title == "Added split transaction")
    }

    @Test func splitChildEditProducesOneEditedHistoryAction() async throws {
        let fixture = try await makeFixture(rows: [])
        defer { cleanUp(fixture) }

        try await execute("""
        INSERT INTO transactions (
            id, isParent, isChild, acct, amount, description, date, sort_order, parent_id
        ) VALUES
            ('split-parent', 1, 0, 'account', -1000, 'payee', 20260906, 20, NULL),
            ('split-child-1', 0, 1, 'account', -600, 'payee', 20260906, 19, 'split-parent'),
            ('split-child-2', 0, 1, 'account', -400, 'payee', 20260906, 18, 'split-parent')
        """, in: fixture)

        let store = fixture.store
        store.transactions = await page(["split-parent"], in: fixture)
        let observer = HistoryObserver(store: store)
        await observer.drainForTesting()

        try await execute(
            "UPDATE transactions SET amount = -700 WHERE id = 'split-child-1'",
            in: fixture
        )
        store.transactions = await page(["split-parent"], in: fixture)
        await observer.drainForTesting()

        #expect(HistoryStore.shared.actions.count == 1)
        let action = try #require(HistoryStore.shared.actions.first)
        #expect(action.kind == .edited)
        #expect(action.before.contains { $0.id == "split-child-1" && $0.amount == -600 })
        #expect(action.after.contains { $0.id == "split-child-1" && $0.amount == -700 })
        #expect(action.title == "Edited split transaction")
    }

    @Test func reloadOfSameBudgetResetsBaseline() async throws {
        let fixture = try await makeFixture(rows: ["original"])
        defer { cleanUp(fixture) }
        let store = fixture.store
        let observer = HistoryObserver(store: store)
        await observer.drainForTesting()

        store.isLoading = true
        try await execute("UPDATE transactions SET tombstone = 1 WHERE id = 'original'", in: fixture)
        try await insert("reloaded", into: fixture)
        store.transactions = await page(["reloaded"], in: fixture)
        await observer.drainForTesting()
        store.isLoading = false
        store.transactions = await page(["reloaded"], in: fixture)
        await observer.drainForTesting()

        #expect(HistoryStore.shared.actions.isEmpty)
    }

    @Test func addProducesOneCreatedAction() async throws {
        let fixture = try await makeFixture(rows: ["existing"])
        defer { cleanUp(fixture) }
        let store = fixture.store
        let observer = HistoryObserver(store: store)
        await observer.drainForTesting()

        try await insert("added", into: fixture)
        store.transactions = await page(["existing", "added"], in: fixture)
        await observer.drainForTesting()

        #expect(HistoryStore.shared.actions.count == 1)
        #expect(HistoryStore.shared.actions.first?.kind == .created)
        #expect(HistoryStore.shared.actions.first?.after.map(\.id) == ["added"])
    }

    @Test func editProducesOneEditedAction() async throws {
        let fixture = try await makeFixture(rows: ["edited"])
        defer { cleanUp(fixture) }
        let store = fixture.store
        let observer = HistoryObserver(store: store)
        await observer.drainForTesting()

        try await execute("UPDATE transactions SET amount = -1200 WHERE id = 'edited'", in: fixture)
        store.transactions = await page(["edited"], in: fixture)
        await observer.drainForTesting()

        #expect(HistoryStore.shared.actions.count == 1)
        #expect(HistoryStore.shared.actions.first?.kind == .edited)
        #expect(HistoryStore.shared.actions.first?.before.first?.amount == -1000)
        #expect(HistoryStore.shared.actions.first?.after.first?.amount == -1200)
    }

    @Test func deleteProducesOneDeletedAction() async throws {
        let fixture = try await makeFixture(rows: ["deleted"])
        defer { cleanUp(fixture) }
        let store = fixture.store
        let observer = HistoryObserver(store: store)
        await observer.drainForTesting()

        try await execute("UPDATE transactions SET tombstone = 1 WHERE id = 'deleted'", in: fixture)
        store.transactions = []
        await observer.drainForTesting()

        #expect(HistoryStore.shared.actions.count == 1)
        #expect(HistoryStore.shared.actions.first?.kind == .deleted)
        #expect(HistoryStore.shared.actions.first?.before.first?.id == "deleted")
        #expect(HistoryStore.shared.actions.first?.after.first?.tombstone == true)
    }

    @Test func publicationDuringSyncRefreshProducesNoHistoryAction() async throws {
        let fixture = try await makeFixture(rows: ["remote"])
        defer { cleanUp(fixture) }
        let store = fixture.store
        let observer = HistoryObserver(store: store)
        await observer.drainForTesting()

        // Mirror a real remote sync: PR #544 identifies rows written by
        // another device from the messages_crdt HLC node suffix.
        try await execute("UPDATE transactions SET amount = -1800 WHERE id = 'remote'", in: fixture)
        try await execute("""
        INSERT INTO messages_crdt (timestamp, dataset, row, column, value)
        VALUES ('2026-09-06T00:00:01.000Z-0000-aaaaaaaaaaaaaaaa', 'transactions', 'remote', 'amount', x'00')
        """, in: fixture)
        store.transactions = await page(["remote"], in: fixture)
        await observer.drainForTesting()

        #expect(HistoryStore.shared.actions.isEmpty)
    }

    /// The reported bug: adding a transaction to a full page pushes the
    /// oldest row off it, which History recorded as a deletion.
    @Test func rowPushedOffThePageIsNotRecordedAsDeleted() async throws {
        let fixture = try await makeFixture(rows: [])
        defer { cleanUp(fixture) }
        try await insert("newer", date: 20_260_906, into: fixture)
        try await insert("oldest", date: 20_250_101, into: fixture)
        let store = fixture.store
        store.transactions = await page(["newer", "oldest"], in: fixture)
        let observer = HistoryObserver(store: store)
        await observer.drainForTesting()

        try await insert("added", date: 20_260_907, into: fixture)
        store.transactions = await page(["added", "newer"], in: fixture)
        await observer.drainForTesting()

        #expect(HistoryStore.shared.actions.count == 1)
        #expect(HistoryStore.shared.actions.first?.kind == .created)
        #expect(HistoryStore.shared.actions.first?.after.map(\.id) == ["added"])
    }

    /// Deleting from a full page pulls the next-oldest row onto it. Recording
    /// that row as created made Undo tombstone a transaction nobody touched.
    @Test func rowPulledOntoThePageIsNotRecordedAsCreated() async throws {
        let fixture = try await makeFixture(rows: [])
        defer { cleanUp(fixture) }
        try await insert("deleted", date: 20_260_906, into: fixture)
        try await insert("newer", date: 20_260_905, into: fixture)
        try await insert("older", date: 20_250_101, into: fixture)
        let store = fixture.store
        store.transactions = await page(["deleted", "newer"], in: fixture)
        let observer = HistoryObserver(store: store)
        await observer.drainForTesting()

        try await execute("UPDATE transactions SET tombstone = 1 WHERE id = 'deleted'", in: fixture)
        store.transactions = await page(["newer", "older"], in: fixture)
        await observer.drainForTesting()

        #expect(HistoryStore.shared.actions.count == 1)
        #expect(HistoryStore.shared.actions.first?.kind == .deleted)
        #expect(HistoryStore.shared.actions.first?.before.map(\.id) == ["deleted"])
    }

    /// A sync can land between a local publication and the read that diffs
    /// it. Rows written by another node are sync changes, not the user's.
    @Test func remoteWriteReadByLocalPublicationIsNotRecorded() async throws {
        let fixture = try await makeFixture(rows: ["local", "remote"])
        defer { cleanUp(fixture) }
        let store = fixture.store
        let observer = HistoryObserver(store: store)
        await observer.drainForTesting()

        try await execute("UPDATE transactions SET amount = -1200 WHERE id = 'local'", in: fixture)
        try await execute("UPDATE transactions SET amount = -1800 WHERE id = 'remote'", in: fixture)
        try await execute("""
        INSERT INTO messages_crdt (timestamp, dataset, row, column, value)
        VALUES ('2026-09-06T00:00:00.000Z-0000-aaaaaaaaaaaaaaaa', 'transactions', 'remote', 'amount', x'00')
        """, in: fixture)
        store.transactions = await page(["local", "remote"], in: fixture)
        await observer.drainForTesting()

        #expect(HistoryStore.shared.actions.count == 1)
        #expect(HistoryStore.shared.actions.first?.kind == .edited)
        #expect(HistoryStore.shared.actions.first?.after.map(\.id) == ["local"])
    }

    @Test func editToRowOffThePageIsRecordedAndUndoable() async throws {
        let fixture = try await makeFixture(rows: ["newer"])
        defer { cleanUp(fixture) }
        try await insert("old", date: 20_250_101, into: fixture)
        let store = fixture.store
        store.transactions = await page(["newer"], in: fixture)
        let observer = HistoryObserver(store: store)
        await observer.drainForTesting()

        try await execute("UPDATE transactions SET amount = -1200 WHERE id = 'old'", in: fixture)
        store.transactions = await page(["newer"], in: fixture)
        await observer.drainForTesting()

        let action = try #require(HistoryStore.shared.actions.first)
        #expect(HistoryStore.shared.actions.count == 1)
        #expect(action.kind == .edited)
        #expect(action.after.map(\.id) == ["old"])

        await HistoryStore.shared.undo(action, using: store)
        await observer.drainForTesting()

        #expect(HistoryStore.shared.errorMessage == nil)
        let amount = try await fixture.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT amount FROM transactions WHERE id = 'old'")
        }
        #expect(amount == -1000)
    }
}
