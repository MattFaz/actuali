import Foundation
import Testing
@testable import Actuali

@MainActor
struct CrossoverEngineTests {

    private func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var c = DateComponents(); c.year = year; c.month = month; c.day = day
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func tx(date: Int, amount: Int, account: String = "a1", category: String? = nil) -> Transaction {
        Transaction(
            id: UUID().uuidString,
            accountId: account, date: date, amount: amount,
            payeeId: nil, payeeName: nil, categoryId: category, categoryName: nil,
            notes: nil, cleared: false, reconciled: false,
            transferId: nil, isParent: false, parentId: nil,
            tombstone: false, sortOrder: nil, importedPayee: nil
        )
    }

    // `Category` alone is ambiguous in the test target (clashes with the ObjC
    // runtime's Category typedef), so qualify the app type.
    private func cat(_ id: String, isIncome: Bool = false, hidden: Bool = false) -> Actuali.Category {
        Actuali.Category(id: id, name: id, groupId: "g1", isIncome: isIncome, hidden: hidden, sortOrder: 0)
    }

    private var categories: [Actuali.Category] {
        [cat("food"), cat("salary", isIncome: true), cat("secret", hidden: true)]
    }

    private func meta(
        expenseCategoryIds: [String]? = nil,
        incomeAccountIds: [String]? = nil,
        timeFrame: WidgetTimeFrame? = nil,
        safeWithdrawalRate: Double? = nil,
        estimatedReturn: Double? = nil,
        expectedContribution: Double? = nil,
        projectionType: CrossoverMeta.ProjectionType? = nil,
        showHiddenCategories: Bool? = nil,
        expenseAdjustmentFactor: Double? = nil
    ) -> CrossoverMeta {
        CrossoverMeta(
            name: nil,
            expenseCategoryIds: expenseCategoryIds,
            incomeAccountIds: incomeAccountIds,
            timeFrame: timeFrame,
            safeWithdrawalRate: safeWithdrawalRate,
            estimatedReturn: estimatedReturn,
            expectedContribution: expectedContribution,
            projectionType: projectionType,
            showHiddenCategories: showHiddenCategories,
            expenseAdjustmentFactor: expenseAdjustmentFactor
        )
    }

    @Test func expenseBucketingByMonthForSelectedCategories() {
        // Range is earliest tx month through the previous month (May 2026).
        let transactions = [
            tx(date: 20260110, amount: -1000, category: "food"),
            tx(date: 20260205, amount: -2000, category: "food"),
            tx(date: 20260220, amount: -500, category: "food"),
            tx(date: 20260215, amount: 90000, category: "salary"),   // income category — excluded
            tx(date: 20260310, amount: -700, category: "secret"),    // hidden — excluded by default
            tx(date: 20260601, amount: -300, category: "food")       // current month — outside range
        ]
        let result = CrossoverEngine.compute(
            meta: meta(incomeAccountIds: ["inv"]),
            transactions: transactions, categories: categories,
            accountIds: ["a1", "inv"], today: utcDate(2026, 6, 15)
        )
        let historical = result.points.filter { !$0.isProjection }
        #expect(historical.count == 5)  // Jan..May
        #expect(historical.map(\.expensesCents) == [1000, 2500, 0, 0, 0])

        // showHiddenCategories includes the hidden category's spending.
        let withHidden = CrossoverEngine.compute(
            meta: meta(incomeAccountIds: ["inv"], showHiddenCategories: true),
            transactions: transactions, categories: categories,
            accountIds: ["a1", "inv"], today: utcDate(2026, 6, 15)
        )
        #expect(withHidden.points.filter { !$0.isProjection }.map(\.expensesCents)
                == [1000, 2500, 700, 0, 0])
    }

    @Test func incomeAccountBalanceAccumulation() {
        let transactions = [
            tx(date: 20260115, amount: 100_000, account: "inv"),
            tx(date: 20260320, amount: 50_000, account: "inv"),
            tx(date: 20260112, amount: -1000, account: "a1", category: "food")
        ]
        let result = CrossoverEngine.compute(
            meta: meta(incomeAccountIds: ["inv"]),
            transactions: transactions, categories: categories,
            accountIds: ["a1", "inv"], today: utcDate(2026, 6, 15)
        )
        let historical = result.points.filter { !$0.isProjection }
        #expect(historical.map(\.nestEggCents) == [100_000, 100_000, 150_000, 150_000, 150_000])
        // Monthly income = balance * (0.04 / 12).
        #expect(historical.last?.investmentIncomeCents == 500)
        #expect(result.lastKnownBalanceCents == 150_000)
        #expect(result.lastKnownMonthlyIncomeCents == 500)
        // Annualized CAGR: monthly (1.5)^(1/4) - 1 over 4 steps → 1.5^3 - 1.
        #expect(abs((result.historicalReturn ?? 0) - 2.375) < 1e-9)
    }

    @Test func staticTimeFrameFoldsPriorTransactionsIntoStartingBalance() {
        let transactions = [
            tx(date: 20260115, amount: 100_000, account: "inv"),
            tx(date: 20260320, amount: 50_000, account: "inv")
        ]
        let result = CrossoverEngine.compute(
            meta: meta(
                incomeAccountIds: ["inv"],
                timeFrame: WidgetTimeFrame(start: "2026-03", end: "2026-05", mode: .static)
            ),
            transactions: transactions, categories: categories,
            accountIds: ["inv"], today: utcDate(2026, 6, 15)
        )
        let historical = result.points.filter { !$0.isProjection }
        #expect(historical.count == 3)  // Mar..May
        #expect(historical.map(\.nestEggCents) == [150_000, 150_000, 150_000])
        #expect(historical.first?.month == utcDate(2026, 3, 1))
    }

    // Expenses [100, 100, 110, 90, 1000, 1200]:
    //   median = 105; MAD = median(|v - 105|) = median([15,5,5,5,895,1095]) = 10;
    //   Hampel bounds = 105 ± 1.4826 * 10 * 3 = [60.522, 149.478] → drops 1000
    //   and 1200 → median([90,100,100,110]) = 100. Mean = 2600/6 ≈ 433.33.
    private var projectionFixture: [Transaction] {
        [
            tx(date: 20260110, amount: -100, category: "food"),
            tx(date: 20260210, amount: -100, category: "food"),
            tx(date: 20260310, amount: -110, category: "food"),
            tx(date: 20260410, amount: -90, category: "food"),
            tx(date: 20260510, amount: -1000, category: "food"),
            tx(date: 20260610, amount: -1200, category: "food"),
            tx(date: 20260115, amount: 100_000, account: "inv")
        ]
    }

    private func projectionResult(_ type: CrossoverMeta.ProjectionType) -> CrossoverData {
        CrossoverEngine.compute(
            meta: meta(incomeAccountIds: ["inv"], projectionType: type),
            transactions: projectionFixture, categories: categories,
            accountIds: ["a1", "inv"], today: utcDate(2026, 7, 15)
        )
    }

    @Test func hampelProjectionRejectsOutliers() {
        let result = projectionResult(.hampel)
        let firstProjection = result.points.first { $0.isProjection }
        #expect(firstProjection?.expensesCents == 100)
        #expect(firstProjection?.adjustedExpensesCents == 100)
        // Balance is flat 100k → income 333 ≥ 100, crossover on the first
        // projected month.
        #expect(result.crossoverMonth == utcDate(2026, 7, 1))
    }

    @Test func medianProjectionKeepsOutliers() {
        let result = projectionResult(.median)
        #expect(result.points.first { $0.isProjection }?.expensesCents == 105)
    }

    @Test func meanProjection() {
        let result = projectionResult(.mean)
        #expect(result.points.first { $0.isProjection }?.expensesCents == 433)
        // Income stays at 333 with zero growth — mean expenses are never covered.
        #expect(result.crossoverMonth == nil)
        #expect(result.yearsToRetire == nil)
    }

    @Test func safeWithdrawalRateMath() {
        let transactions = [tx(date: 20260110, amount: 100_000, account: "inv")]
        let result = CrossoverEngine.compute(
            meta: meta(incomeAccountIds: ["inv"], safeWithdrawalRate: 0.12),
            transactions: transactions, categories: categories,
            accountIds: ["inv"], today: utcDate(2026, 3, 15)
        )
        // 0.12 / 12 = 1% monthly of a 100,000-cent balance.
        #expect(result.lastKnownMonthlyIncomeCents == 1000)
        #expect(result.points.first?.investmentIncomeCents == 1000)
    }

    @Test func expenseAdjustmentFactorScalesTarget() {
        let transactions = [
            tx(date: 20260110, amount: -1000, category: "food"),
            tx(date: 20260210, amount: -1000, category: "food"),
            tx(date: 20260310, amount: -1000, category: "food"),
            tx(date: 20260115, amount: 100_000, account: "inv")
        ]
        let result = CrossoverEngine.compute(
            meta: meta(
                incomeAccountIds: ["inv"],
                expectedContribution: 100_000,
                expenseAdjustmentFactor: 0.5
            ),
            transactions: transactions, categories: categories,
            accountIds: ["a1", "inv"], today: utcDate(2026, 4, 15)
        )
        // Contribution pushes income to 667 in the first projected month,
        // above the adjusted target of 1000 * 0.5 = 500.
        let firstProjection = result.points.first { $0.isProjection }
        #expect(firstProjection?.expensesCents == 1000)
        #expect(firstProjection?.adjustedExpensesCents == 500)
        #expect(result.targetMonthlyIncomeCents == 500)
        // Target nest egg = target income / monthly SWR = 500 / (0.04/12).
        #expect(result.targetNestEggCents == 150_000)
        #expect(result.crossoverMonth == utcDate(2026, 4, 1))
        #expect(result.yearsToRetire == 0)
    }

    @Test func crossoverDetectionAtKnownMonth() {
        // Balance 100k + 50k/month contribution, zero growth, SWR 4%:
        // income_i = (100000 + 50000 i) * 0.04/12 → 833 at i=3, 1000 at i=4.
        // Flat expenses 999 → crossover on the 4th projected month (Jul 2026).
        let transactions = [
            tx(date: 20260110, amount: -999, category: "food"),
            tx(date: 20260210, amount: -999, category: "food"),
            tx(date: 20260310, amount: -999, category: "food"),
            tx(date: 20260115, amount: 100_000, account: "inv")
        ]
        let result = CrossoverEngine.compute(
            meta: meta(incomeAccountIds: ["inv"], expectedContribution: 50_000),
            transactions: transactions, categories: categories,
            accountIds: ["a1", "inv"], today: utcDate(2026, 4, 15)
        )
        #expect(result.crossoverMonth == utcDate(2026, 7, 1))
        #expect(result.points.count == 3 + 4)  // Jan..Mar + 4 projected months
        #expect(result.points.last?.isProjection == true)
        #expect(result.yearsToRetire == 0.25)  // 3 months out
        #expect(result.targetMonthlyIncomeCents == 999)
        #expect(result.lastKnownMonthlyExpensesCents == 999)
    }

    @Test func emptyIncomeAccountsProducesEmptyData() {
        let result = CrossoverEngine.compute(
            meta: meta(incomeAccountIds: []),
            transactions: [tx(date: 20260110, amount: -1000, category: "food")],
            categories: categories, accountIds: [], today: utcDate(2026, 6, 15)
        )
        #expect(result == .empty)
    }
}
