import Foundation
import GRDB
import Testing
@testable import Actuali

struct AddTransactionPreviewTests {
    @Test func cancelledPreviewDoesNotReachLookup() async {
        let task = Task {
            try await AddTransactionView.debounceAutomaticCategory()
            Issue.record("Cancelled preview reached category lookup")
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test func settledPreviewWaitsForTypingToPause() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        try await AddTransactionView.debounceAutomaticCategory()
        #expect(start.duration(to: clock.now) >= .milliseconds(300))
    }

    @Test(arguments: ["notes", "amount", "date", "cleared"])
    func ruleFieldsStillInvalidatePreview(field: String) {
        let input = AddTransactionView.AutomaticCategoryInput(
            accountId: "acct-1", type: .expense, amount: "10.00",
            payeeId: nil, payeeName: "Cafe", notes: "", date: Date(),
            cleared: false, isSplit: false, isEditing: false,
            categoryIsExplicit: false, applyRules: true
        )
        var changed = input
        switch field {
        case "notes": changed.notes = "business lunch"
        case "amount": changed.amount = "20.00"
        case "date": changed.date = input.date.addingTimeInterval(86400)
        default: changed.cleared = true
        }
        #expect(changed != input)
    }

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
        try await AddTransactionView.debounceAutomaticCategory()
        let after = try await store.automaticCategoryPreview(for: form)
        #expect(after.resultCategoryId == "cat-dining")
    }
}
