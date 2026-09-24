import Foundation
import GRDB
import Testing
@testable import Actuali

/// One leg of a transfer or charge, projected out of GRDB inside the read
/// closure — `Row` isn't `Sendable` and can't cross the boundary. File scope
/// rather than nested, so it doesn't inherit the test's `@MainActor` and can
/// be built on the database's own queue.
private struct Posted: Sendable, Equatable {
    let accountId: String
    let amount: Int
    let categoryId: String?
    let isTransfer: Bool
}

/// Recording a loan payment end to end: three rows land, the loan account
/// nets to the principal, and the paired category sees the whole payment.
@MainActor
struct BudgetStoreLoanPaymentTests {
    private let config = LoanConfig(
        originalBalance: 2_200_000,
        annualRatePercent: 6,
        minimumPayment: 36500,
        escrowOrFees: nil
    )

    private struct Fixture {
        let store: BudgetStore
        let checking: Account
        let loan: Account
        let databasePath: URL
    }

    private func makeFixture(
        startingCash: Int = 500_000,
        owing: Int = -2_200_000
    ) async throws -> (Fixture, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loan-payment-\(UUID().uuidString)", isDirectory: true)
        let manager = BudgetFileManager(rootDirectoryForTesting: root)
        let budgetId = "budget-\(UUID().uuidString)"

        let dir = manager.budgetDirectory(for: budgetId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbQueue = try DatabaseQueue(path: manager.databasePath(for: budgetId).path)
        try await dbQueue.write { db in
            try db.execute(sql: BudgetStoreInitialSyncTests.upstreamSchema)
        }
        try JSONEncoder().encode(BudgetMetadata(
            id: budgetId, budgetName: "Seed", cloudFileId: "cf-1", groupId: "group-1",
            resetClock: nil, lastUploaded: nil, encryptKeyId: nil
        )).write(to: manager.metadataPath(for: budgetId))

        let store = BudgetStore.previewInstance()
        store.setFileManagerForTesting(manager)
        await store.loadLocalBudget(budgetId)
        // `loadLocalBudget` opens the database and configures sync but leaves
        // `currentBudgetId` to its callers — `downloadBudget` and
        // `createBudget` both set it before calling in. Without it `setLoan`
        // returns on its first guard and stores nothing, silently.
        store.currentBudgetId = budgetId

        let checking = try await store.createAccount(
            name: "Checking", offBudget: false, startingBalanceCents: startingCash
        )
        let loan = try await store.createAccount(
            name: "Car Loan", offBudget: true, startingBalanceCents: owing
        )
        await store.setLoan(accountId: loan.id, config: config)
        // Fail here rather than as a scatter of downstream expectations: a
        // fixture that quietly stops storing the loan makes every test that
        // needs one fail for a reason none of them name.
        try #require(store.loanConfigs[loan.id] == config)

        return (
            Fixture(
                store: store, checking: checking, loan: loan,
                databasePath: manager.databasePath(for: budgetId)
            ),
            root
        )
    }

    /// Every live row, so a test can assert on the shape of what was posted
    /// rather than on the paged in-memory list.
    private func posted(in databasePath: URL) async throws -> [Posted] {
        let dbQueue = try DatabaseQueue(path: databasePath.path)
        return try await dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT acct, amount, category, transferred_id, starting_balance_flag
                FROM transactions
                WHERE (tombstone = 0 OR tombstone IS NULL)
                  AND (starting_balance_flag = 0 OR starting_balance_flag IS NULL)
            """).map { row in
                let accountId: String? = row["acct"]
                let amount: Int? = row["amount"]
                let categoryId: String? = row["category"]
                let transferId: String? = row["transferred_id"]
                return Posted(
                    accountId: accountId ?? "",
                    amount: amount ?? 0,
                    categoryId: categoryId,
                    isTransfer: transferId != nil
                )
            }
        }
    }

    private func balance(_ store: BudgetStore, _ accountId: String) -> Int? {
        store.accounts.first { $0.id == accountId }?.balance
    }

    @Test func aPaymentNetsToPrincipalOnTheLoanAndTheFullAmountOnTheFundingAccount() async throws {
        let (fixture, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        try await fixture.store.recordLoanPayment(
            accountId: fixture.loan.id,
            fromAccountId: fixture.checking.id,
            payment: 36500,
            interest: 11000,
            escrow: 0,
            date: 20_260_901,
            notes: nil
        )

        // $365 in, $110 straight back out as interest: $255 off the balance.
        #expect(balance(fixture.store, fixture.loan.id) == -2_200_000 + 25500)
        #expect(balance(fixture.store, fixture.checking.id) == 500_000 - 36500)
    }

    @Test func aPaymentPostsTheChargeSeparatelyFromTheTransfer() async throws {
        let (fixture, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        try await fixture.store.recordLoanPayment(
            accountId: fixture.loan.id,
            fromAccountId: fixture.checking.id,
            payment: 36500,
            interest: 11000,
            escrow: 0,
            date: 20_260_901,
            notes: nil
        )

        let rows = try await posted(in: fixture.databasePath)
        let onLoan = rows.filter { $0.accountId == fixture.loan.id }

        // The transfer's inflow plus the lender's charge, kept apart so the
        // interest stays editable and visible in the register.
        #expect(onLoan.count == 2)
        #expect(onLoan.contains { $0.amount == 36500 && $0.isTransfer })
        #expect(onLoan.contains { $0.amount == -11000 && !$0.isTransfer })
        #expect(rows.contains { $0.accountId == fixture.checking.id && $0.amount == -36500 })
    }

    @Test func aMortgagePaymentPostsEscrowAsItsOwnCharge() async throws {
        let (fixture, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        try await fixture.store.recordLoanPayment(
            accountId: fixture.loan.id,
            fromAccountId: fixture.checking.id,
            payment: 36500,
            interest: 11000,
            escrow: 20000,
            date: 20_260_901,
            notes: nil
        )

        let onLoan = try await posted(in: fixture.databasePath)
            .filter { $0.accountId == fixture.loan.id }

        #expect(onLoan.count == 3)
        #expect(onLoan.contains { $0.amount == -20000 })
        // $365 less $110 interest less $200 escrow leaves $55 of principal.
        #expect(balance(fixture.store, fixture.loan.id) == -2_200_000 + 5500)
    }

    /// The whole payment lands on the category while the balance moves by the
    /// principal alone — YNAB's Activity and Overview figures, falling out of
    /// the double entry rather than being tracked separately.
    @Test func thePairedCategoryCarriesTheWholePaymentNotJustThePrincipal() async throws {
        let (fixture, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let group = try await fixture.store.createCategoryGroup(name: "Debt")
        let category = try await fixture.store.createCategory(name: "Car Loan", groupId: group.id)
        await fixture.store.pairLoan(accountId: fixture.loan.id, categoryId: category.id)

        try await fixture.store.recordLoanPayment(
            accountId: fixture.loan.id,
            fromAccountId: fixture.checking.id,
            payment: 36500,
            interest: 11000,
            escrow: 0,
            date: 20_260_901,
            notes: nil
        )

        let rows = try await posted(in: fixture.databasePath)
        let fundingLeg = rows.first { $0.accountId == fixture.checking.id && $0.isTransfer }
        let loanLeg = rows.first { $0.accountId == fixture.loan.id && $0.isTransfer }

        #expect(fundingLeg?.amount == -36500)
        #expect(fundingLeg?.categoryId == category.id)
        // Actual allows a category only on the on-budget leg.
        #expect(loanLeg?.categoryId == nil)
    }

    @Test func anUnpairedLoanStillRecordsThePaymentUncategorized() async throws {
        let (fixture, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        try await fixture.store.recordLoanPayment(
            accountId: fixture.loan.id,
            fromAccountId: fixture.checking.id,
            payment: 36500,
            interest: 11000,
            escrow: 0,
            date: 20_260_901,
            notes: nil
        )

        let rows = try await posted(in: fixture.databasePath)

        #expect(rows.allSatisfy { $0.categoryId == nil })
        #expect(balance(fixture.store, fixture.loan.id) == -2_200_000 + 25500)
    }

    @Test func totalPaidCountsPaymentsAndNotTheLendersCharges() async throws {
        let (fixture, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        for _ in 0..<2 {
            try await fixture.store.recordLoanPayment(
                accountId: fixture.loan.id,
                fromAccountId: fixture.checking.id,
                payment: 36500,
                interest: 11000,
                escrow: 0,
                date: 20_260_901,
                notes: nil
            )
        }

        // Two payments in full, interest included — the Activity figure. The
        // balance has only moved by the two lots of principal.
        let totalPaid = await fixture.store.totalPaidIntoLoan(accountId: fixture.loan.id)
        #expect(totalPaid == 73000)
        #expect(balance(fixture.store, fixture.loan.id) == -2_200_000 + 51000)
    }

    // MARK: - Guards

    @Test func aPaymentNeedsADifferentAccountToComeFrom() async throws {
        let (fixture, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: BudgetStoreError.transferAccountsMatch) {
            try await fixture.store.recordLoanPayment(
                accountId: fixture.loan.id,
                fromAccountId: fixture.loan.id,
                payment: 36500,
                interest: 11000,
                escrow: 0,
                date: 20_260_901,
                notes: nil
            )
        }
    }

    @Test func aPaymentOfNothingIsRefused() async throws {
        let (fixture, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: BudgetStoreError.transferAmountNotPositive) {
            try await fixture.store.recordLoanPayment(
                accountId: fixture.loan.id,
                fromAccountId: fixture.checking.id,
                payment: 0,
                interest: 0,
                escrow: 0,
                date: 20_260_901,
                notes: nil
            )
        }
    }

    // MARK: - Pairing

    @Test func pairingSurvivesAndCanBeUndone() async throws {
        let (fixture, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let group = try await fixture.store.createCategoryGroup(name: "Debt")
        let category = try await fixture.store.createCategory(name: "Car Loan", groupId: group.id)

        await fixture.store.pairLoan(accountId: fixture.loan.id, categoryId: category.id)
        #expect(fixture.store.loanConfigs[fixture.loan.id]?.categoryId == category.id)
        #expect(fixture.store.pairedLoanCategory(for: fixture.loan.id)?.id == category.id)

        await fixture.store.pairLoan(accountId: fixture.loan.id, categoryId: nil)
        #expect(fixture.store.loanConfigs[fixture.loan.id]?.categoryId == nil)
        #expect(fixture.store.pairedLoanCategory(for: fixture.loan.id) == nil)
    }

    /// Pairing leaves the terms alone — it reads the stored config rather
    /// than rebuilding one, so an edit made elsewhere isn't overwritten.
    @Test func pairingKeepsTheLoansTerms() async throws {
        let (fixture, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        await fixture.store.pairLoan(accountId: fixture.loan.id, categoryId: "cat_car")

        let stored = fixture.store.loanConfigs[fixture.loan.id]
        #expect(stored?.originalBalance == config.originalBalance)
        #expect(stored?.minimumPayment == config.minimumPayment)
        #expect(stored?.annualRatePercent == config.annualRatePercent)
    }

    // MARK: - Snoozing the target

    private func pairedLoan(_ fixture: Fixture) async -> String {
        await fixture.store.pairLoan(accountId: fixture.loan.id, categoryId: "cat_car")
        return "cat_car"
    }

    @Test func snoozingTheTargetCoversThatMonthAlone() async throws {
        let (fixture, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let categoryId = await pairedLoan(fixture)

        await fixture.store.snoozeLoanTarget(accountId: fixture.loan.id, month: "2026-09")

        #expect(fixture.store.snoozedLoanCategoryIds(inMonth: "2026-09") == [categoryId])
        #expect(fixture.store.snoozedLoanCategoryIds(inMonth: "2026-10").isEmpty)
    }

    @Test func clearingTheSnoozeLetsTheTargetRunAgain() async throws {
        let (fixture, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await pairedLoan(fixture)

        await fixture.store.snoozeLoanTarget(accountId: fixture.loan.id, month: "2026-09")
        await fixture.store.snoozeLoanTarget(accountId: fixture.loan.id, month: nil)

        #expect(fixture.store.snoozedLoanCategoryIds(inMonth: "2026-09").isEmpty)
        #expect(fixture.store.loanConfigs[fixture.loan.id]?.targetSnoozedMonth == nil)
    }

    /// Nothing to skip without a paired category — the snooze is stored, but
    /// it can't name a category for the template run to pass over.
    @Test func snoozingAnUnpairedLoanExcludesNothing() async throws {
        let (fixture, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        await fixture.store.snoozeLoanTarget(accountId: fixture.loan.id, month: "2026-09")

        #expect(fixture.store.loanConfigs[fixture.loan.id]?.targetSnoozedMonth == "2026-09")
        #expect(fixture.store.snoozedLoanCategoryIds(inMonth: "2026-09").isEmpty)
    }

    /// A closed loan drops out through the same `activeLoanConfigs` predicate
    /// every other loan surface uses, so a stale snooze on a paid-off loan
    /// can't keep suppressing its old category.
    @Test func aClosedLoansSnoozeStopsApplying() async throws {
        let (fixture, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await pairedLoan(fixture)
        await fixture.store.snoozeLoanTarget(accountId: fixture.loan.id, month: "2026-09")
        #expect(!fixture.store.snoozedLoanCategoryIds(inMonth: "2026-09").isEmpty)

        fixture.store.accounts = fixture.store.accounts.map { account in
            var copy = account
            if copy.id == fixture.loan.id {
                copy.closed = true
            }
            return copy
        }

        #expect(fixture.store.snoozedLoanCategoryIds(inMonth: "2026-09").isEmpty)
    }

    /// A category that no longer exists leaves the loan reading as unpaired,
    /// so no screen names something the user can't open.
    @Test func aPairedCategoryThatVanishedReadsAsUnpaired() async throws {
        let (fixture, root) = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        await fixture.store.pairLoan(accountId: fixture.loan.id, categoryId: "cat_gone")

        #expect(fixture.store.loanConfigs[fixture.loan.id]?.categoryId == "cat_gone")
        #expect(fixture.store.pairedLoanCategory(for: fixture.loan.id) == nil)
    }
}
