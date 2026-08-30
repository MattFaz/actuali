import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct BudgetStoreCreditLimitTests {

    /// Points the store at a throwaway budget with configured database and sync client.
    private func withStore(_ body: @MainActor (BudgetStore) async throws -> Void) async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let queue = try DatabaseQueue(path: tempURL.path)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
                CREATE TABLE messages_crdt (id INTEGER PRIMARY KEY, timestamp TEXT NOT NULL UNIQUE, dataset TEXT NOT NULL, row TEXT NOT NULL, column TEXT NOT NULL, value BLOB NOT NULL);
            """)
        }
        let database = try BudgetDatabase(path: tempURL)
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        let store = BudgetStore.previewInstance()
        store.configureForTesting(database: database, syncClient: syncClient)
        store.currentBudgetId = "test-budget"
        try await body(store)
    }

    private func account(id: String, name: String, type: AccountType = .credit,
                         closed: Bool = false, balance: Int = 0) -> Account {
        Account(id: id, name: name, type: type, offBudget: false, closed: closed,
                sortOrder: 0, balance: balance)
    }

    /// A card's balance is negative while money is owed, so headroom is the limit
    /// plus the balance — the sign is the whole point of this test.
    @Test func availableCreditIsTheLimitLessWhatIsOwed() async throws {
        try await withStore { store in
            store.accounts = [account(id: "acct_card", name: "Card", balance: -614_900)]
            await store.setCreditCard(accountId: "acct_card", statementDay: 25, limit: 1_000_000)

            #expect(store.creditCardLimits["acct_card"] == 1_000_000)
            #expect(store.availableCredit(for: "acct_card") == 385_100)

            // Over the limit reads negative rather than clamping — being $100
            // over is a fact worth showing.
            store.accounts = [account(id: "acct_card", name: "Card", balance: -1_010_000)]
            #expect(store.availableCredit(for: "acct_card") == -10_000)

            // Overpaid card: headroom exceeds the limit.
            store.accounts = [account(id: "acct_card", name: "Card", balance: 5_000)]
            #expect(store.availableCredit(for: "acct_card") == 1_005_000)
        }
    }

    @Test func availableCreditIsNilWithoutALimitOrAnActiveCard() async throws {
        try await withStore { store in
            store.accounts = [
                account(id: "acct_nolimit", name: "No Limit", balance: -1_000),
                account(id: "acct_closed", name: "Closed", closed: true, balance: -1_000),
                account(id: "acct_untracked", name: "Checking", type: .checking, balance: -1_000),
            ]
            await store.setCreditCard(accountId: "acct_nolimit", statementDay: 15, limit: nil)
            await store.setCreditCard(accountId: "acct_closed", statementDay: 15, limit: 500_000)

            #expect(store.availableCredit(for: "acct_nolimit") == nil)
            #expect(store.availableCredit(for: "acct_closed") == nil)
            #expect(store.availableCredit(for: "acct_untracked") == nil)
            #expect(store.availableCredit(for: "acct_missing") == nil)
        }
    }

    @Test func limitClearsWithTheCardAndOnAnEmptyEntry() async throws {
        try await withStore { store in
            await store.setCreditCard(accountId: "acct_card", statementDay: 25, limit: 1_000_000)

            // Untracking the card must not leave the limit behind to be picked up
            // by a later card on the same account.
            await store.setCreditCard(accountId: "acct_card", statementDay: nil, limit: nil)
            #expect(store.creditCardLimits["acct_card"] == nil)

            // An emptied field in the sheet clears a previously stored limit...
            await store.setCreditCard(accountId: "acct_card", statementDay: 25, limit: 1_000_000)
            await store.setCreditCard(accountId: "acct_card", statementDay: 25, limit: nil)
            #expect(store.creditCardLimits["acct_card"] == nil)

            // ...while setting a limit updates the stored config.
            await store.setCreditCard(accountId: "acct_card", statementDay: 3, dueOffsetDays: 25, limit: 1_000_000)
            #expect(store.creditCardLimits["acct_card"] == 1_000_000)
        }
    }

    @Test func limitIsScopedToTheBudgetThatSetIt() async throws {
        try await withStore { store in
            await store.setCreditCard(accountId: "acct_card", statementDay: 15, limit: 1_000_000)

            store.currentBudgetId = "other-budget"
            #expect(store.creditCardLimits.isEmpty)
        }
    }
}
