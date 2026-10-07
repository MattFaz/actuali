import GRDB
import SwiftUI
import Synchronization
import Testing
import UIKit
@testable import Actuali

@MainActor
@Suite(.serialized)
struct AddTransactionInteractionTests {
    @MainActor
    final class HostedForm {
        let controller: UIHostingController<AnyView>
        let window: UIWindow
        let previousWindow: UIWindow?

        init(store: BudgetStore) throws {
            let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            previousWindow = scene.windows.first { $0.isKeyWindow }
            controller = UIHostingController(rootView: AnyView(
                AddTransactionView(accountId: "acct-1", payee: "Cafe", amountCents: 1000)
                    .environmentObject(store)
            ))
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 430, height: 1500)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.view.layoutIfNeeded()
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }

        func notesField() throws -> UITextView {
            func find(in view: UIView) -> UITextView? {
                if let field = view as? UITextView {
                    return field
                }
                for child in view.subviews {
                    if let field = find(in: child) {
                        return field
                    }
                }
                return nil
            }
            let field = find(in: controller.view)
            return try #require(field)
        }

        func enterNotes(_ text: String) throws {
            let field = try notesField()
            field.text = text
            field.delegate?.textViewDidChange?(field)
        }
    }

    static func fixture() async throws -> (BudgetStore, BudgetDatabase, URL) {
        let (database, path) = try await makeTestDatabase(TestSchema.core + [TestSchema.rules])
        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
            INSERT INTO accounts (id, name) VALUES ('acct-1', 'Checking');
            INSERT INTO payees (id, name) VALUES ('cafe', 'Cafe');
            INSERT INTO category_groups (id, name) VALUES ('group-1', 'Spending');
            INSERT INTO categories (id, name, cat_group) VALUES
                ('food', 'Food', 'group-1'), ('business', 'Business', 'group-1');
            INSERT INTO transactions (id, acct, description, category, amount, date)
                VALUES ('history', 'acct-1', 'cafe', 'food', -1000, 20261001);
            INSERT INTO rules (id, conditions, actions) VALUES ('business-notes',
                '[{"op":"contains","field":"notes","value":"business"}]',
                '[{"op":"set","field":"category","value":"business"}]');
            """)
        }
        let store = try await makeTestStore(database: database)
        store.accounts = try await database.fetchAccounts()
        store.payees = [Payee(id: "cafe", name: "Cafe", transferAccountId: nil, tombstone: false)]
        store.categoryGroups = try await database.fetchCategoryGroups()
        return (store, database, path)
    }

    /// The deadline is only a backstop for a lookup that never happens; a
    /// loaded CI runner has needed well over 5s to host the form and fire it.
    static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(predicate())
    }

    @Test func rapidNotesEditsOnlyLookUpTheLatestInput() async throws {
        let (store, database, path) = try await Self.fixture()
        defer { cleanup(path) }
        let reads = Mutex(0)
        try await database.dbQueueForTesting.write { db in
            db.trace { event in
                if case .statement(let statement) = event,
                   statement.sql.hasPrefix("SELECT category FROM transactions") {
                    reads.withLock { $0 += 1 }
                }
            }
        }
        let form = try HostedForm(store: store)
        defer { form.close() }
        try await Self.waitUntil { reads.withLock { $0 } == 1 }
        try await Task.sleep(for: .milliseconds(100))
        reads.withLock { $0 = 0 }

        try form.enterNotes("business")
        try await Task.sleep(for: .milliseconds(100))
        #expect(reads.withLock { $0 } == 0)
        try form.enterNotes("personal")
        try await Self.waitUntil { reads.withLock { $0 } > 0 }
        try await Task.sleep(for: .milliseconds(350))
        #expect(reads.withLock { $0 } == 1)
    }

    @Test func savingDuringPendingPreviewAppliesTheCurrentNotesRule() async throws {
        let (store, database, path) = try await Self.fixture()
        defer { cleanup(path) }
        let reads = Mutex(0)
        try await database.dbQueueForTesting.write { db in
            db.trace { event in
                if case .statement(let statement) = event,
                   statement.sql.hasPrefix("SELECT category FROM transactions") {
                    reads.withLock { $0 += 1 }
                }
            }
        }
        let hosted = try HostedForm(store: store)
        defer { hosted.close() }
        try await Self.waitUntil { reads.withLock { $0 } == 1 }
        try await Task.sleep(for: .milliseconds(100))
        reads.withLock { $0 = 0 }
        try hosted.enterNotes("business lunch")
        await Task.yield()
        #expect(reads.withLock { $0 } == 0)

        // Save must re-evaluate the current notes even while the form still
        // carries its earlier history-based preview.
        let id = try #require(try await store.saveTransaction(.init(
            accountId: "acct-1", type: .expense, amount: "10.00", payeeName: "Cafe",
            transferToAccountId: nil, categoryId: "food", notes: "business lunch",
            date: Date(), cleared: false,
            automaticCategoryPreview: .init(sourceCategoryId: "food", resultCategoryId: "food")
        )))
        let category = try await database.dbQueueForTesting.read { db in
            try String.fetchOne(db, sql: "SELECT category FROM transactions WHERE id = ?", arguments: [id])
        }
        #expect(category == "business")
    }
}
