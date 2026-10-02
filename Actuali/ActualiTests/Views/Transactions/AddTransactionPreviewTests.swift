import Foundation
import GRDB
import Testing
@testable import Actuali

struct AddTransactionPreviewTests {
    @Test func unchangedNotesKeepPreviewEqual() {
        #expect(AddTransactionNoteLinkRows(text: "[Receipt](https://example.com)") ==
            AddTransactionNoteLinkRows(text: "[Receipt](https://example.com)"))
        #expect(AddTransactionNoteLinkRows(text: "https://example.com/old") !=
            AddTransactionNoteLinkRows(text: "https://example.com/new"))
    }

    @MainActor
    @Test func changedNotesStillAssignRuleCategory() async throws {
        let (database, path) = try await makeTestDatabase(TestSchema.core + [TestSchema.rules])
        defer { cleanup(path) }
        let store = try await makeTestStore(database: database)
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
            INSERT INTO rules (id, conditions_op, conditions, actions)
            VALUES ('notes-category', 'and',
                '[{"op":"is","field":"notes","value":"business lunch"}]',
                '[{"op":"set","field":"category","value":"cat-dining"}]')
            """)
        }
        var form = BudgetStore.TransactionForm(
            accountId: "acct-1", type: .expense, amount: "10.00", payeeName: "Cafe",
            transferToAccountId: nil, categoryId: nil, notes: "", date: Date(), cleared: false
        )
        let before = try await store.automaticCategoryPreview(for: form)
        #expect(before.resultCategoryId == nil)

        form.notes = "business lunch"
        let after = try await store.automaticCategoryPreview(for: form)
        #expect(after.resultCategoryId == "cat-dining")
    }
}
