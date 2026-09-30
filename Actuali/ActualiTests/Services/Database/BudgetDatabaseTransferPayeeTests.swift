import Foundation
import GRDB
import Testing
@testable import Actuali

/// Pins payee-name resolution in `fetchTransactions()`: a transfer's payee row
/// carries no name (only `transfer_acct`), so its display name must come from
/// the linked account — matching Actual's `v_payees` view
/// (`COALESCE(__accounts.name, _.name)`). Regular payees keep their own name.
/// Regression for GH #7: transfers rendered with an empty payee.
@MainActor
struct BudgetDatabaseTransferPayeeTests {
    @Test func transferPayeeResolvesToLinkedAccountName() async throws {
        let (db, url) = try await makeTestDatabase(
            TestSchema.accounts, TestSchema.payees, TestSchema.payeeMapping,
            TestSchema.categories, TestSchema.categoryMapping, TestSchema.transactions
        )
        defer { cleanup(url) }

        try await db.dbQueueForTesting.write { conn in
            try conn.execute(sql: """
                INSERT INTO accounts (id, name) VALUES
                    ('acct-checking', 'Checking'),
                    ('acct-savings',  'Savings');

                -- A regular payee (has its own name) and a transfer payee
                -- (no name, transfer_acct points at Savings).
                INSERT INTO payees (id, name, transfer_acct) VALUES
                    ('payee-shop',     'Coffee Shop', NULL),
                    ('payee-transfer', NULL,          'acct-savings');

                INSERT INTO payee_mapping (id, targetId) VALUES
                    ('payee-shop',     'payee-shop'),
                    ('payee-transfer', 'payee-transfer');

                -- One normal spend and one transfer leg out of Checking.
                INSERT INTO transactions (id, acct, description, amount, date, transferred_id) VALUES
                    ('t-spend',    'acct-checking', 'payee-shop',     -550,  20260601, NULL),
                    ('t-transfer', 'acct-checking', 'payee-transfer', -10000, 20260602, 't-other-leg');
            """)
        }

        let txns = try await db.fetchTransactions(accountId: "acct-checking")
        let spend = txns.first { $0.id == "t-spend" }
        let transfer = txns.first { $0.id == "t-transfer" }

        #expect(spend?.payeeName == "Coffee Shop")
        #expect(transfer?.payeeName == "Savings")

        // The payee's transfer_acct rides along so rows can render transfers
        // as transfers and the edit form knows the other side (GH #104).
        #expect(spend?.transferAcct == nil)
        #expect(transfer?.transferAcct == "acct-savings")
    }
}
