import Foundation
import Testing
@testable import Actuali

@MainActor
struct SpendingEngineTests {

    private var asOf: Date {
        var c = DateComponents(); c.year = 2026; c.month = 5; c.day = 14
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func tx(date: Int, amount: Int) -> Transaction {
        Transaction(
            id: UUID().uuidString,
            accountId: "a1", date: date, amount: amount,
            payeeId: nil, payeeName: nil, categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false,
            transferId: nil, isParent: false, parentId: nil,
            tombstone: false, sortOrder: nil, importedPayee: nil
        )
    }

    private func meta(
        conditions: [WidgetRuleCondition]? = nil,
        compare: String? = nil,
        compareTo: String? = nil,
        isLive: Bool? = true,
        mode: SpendingMeta.Mode? = nil,
        averageRange: SpendingAverageRange? = nil
    ) -> SpendingMeta {
        SpendingMeta(name: nil, conditions: conditions, conditionsOp: nil,
                     compare: compare, compareTo: compareTo, isLive: isLive,
                     mode: mode, averageRange: averageRange)
    }

    // Actuali.Category: the ObjC runtime also exports a `Category` type.
    private var budgetCategories: [Actuali.Category] {
        [
            Actuali.Category(id: "groceries", name: "Groceries", groupId: "g1", isIncome: false, hidden: false, sortOrder: 0),
            Actuali.Category(id: "rent", name: "Rent", groupId: "g1", isIncome: false, hidden: false, sortOrder: 1)
        ]
    }

    private var budgetGroups: [CategoryGroup] {
        [CategoryGroup(id: "g1", name: "Expenses", isIncome: false, hidden: false, sortOrder: 0,
                       categories: budgetCategories)]
    }

    // Upstream nets positive amounts (refunds) into spending; income
    // exclusion happens by category upstream (categoryIncome), mirrored by
    // DashboardView.spendingScope(), not by dropping positive amounts.
    @Test func currentMonthNetsRefunds() {
        let transactions = [
            tx(date: 20260501, amount: -10000),
            tx(date: 20260503, amount: 3000),   // refund — nets against spending
            tx(date: 20260504, amount: -2000)
        ]
        let result = SpendingEngine.compute(meta: meta(mode: .average), transactions: transactions, today: asOf)
        #expect(result.currentSpentCents == 9000)
    }

    // Upstream's card reads the cumulative at today's day, so transactions
    // dated later in the current month (scheduled/entered ahead) don't count.
    @Test func currentMonthExcludesFutureDatedTransactions() {
        let transactions = [
            tx(date: 20260510, amount: -10000),
            tx(date: 20260520, amount: -5000)   // after asOf (May 14) — excluded
        ]
        let result = SpendingEngine.compute(meta: meta(mode: .average), transactions: transactions, today: asOf)
        #expect(result.currentSpentCents == 10000)
    }

    // Upstream defaults mode to 'single-month' compared against the previous
    // month through the same day of month — not a 3-month average.
    @Test func defaultModeIsSingleMonthVsPreviousMonth() {
        let transactions = [
            tx(date: 20260410, amount: -8000),
            tx(date: 20260420, amount: -9000),  // past day 14 — excluded from comparison
            tx(date: 20260505, amount: -100)
        ]
        let result = SpendingEngine.compute(meta: meta(mode: nil), transactions: transactions, today: asOf)
        #expect(result.comparisonCents == 8000)
    }

    @Test func singleMonthWithoutCompareToUsesPreviousMonth() {
        let transactions = [
            tx(date: 20260410, amount: -8000),
            tx(date: 20260505, amount: -100)
        ]
        let result = SpendingEngine.compute(meta: meta(mode: .singleMonth), transactions: transactions, today: asOf)
        #expect(result.comparisonCents == 8000)
    }

    // A non-live widget keeps its stored compare/compareTo months verbatim,
    // and past months always use their full-month totals (day-28 bucket).
    @Test func pinnedCompareMonthIsHonored() {
        let transactions = [
            tx(date: 20260305, amount: -4000),
            tx(date: 20260320, amount: -1000),  // past day 14, still counts: full month
            tx(date: 20260210, amount: -2500),
            tx(date: 20260505, amount: -999)    // current month — not the compare month
        ]
        let result = SpendingEngine.compute(
            meta: meta(compare: "2026-03", compareTo: "2026-02", isLive: false, mode: .singleMonth),
            transactions: transactions, today: asOf
        )
        #expect(result.currentSpentCents == 5000)
        #expect(result.comparisonCents == 2500)
    }

    @Test func averageOfPriorMonths() {
        // asOf is 2026-05-14, so prior-month spending is averaged month-to-date
        // (through day 14) over the 3 prior months: Feb, Mar, Apr.
        let transactions = [
            tx(date: 20260210, amount: -10000),  // Feb, within MTD cutoff
            tx(date: 20260310, amount: -10000),  // Mar, within MTD cutoff
            tx(date: 20260410, amount: -10000),  // Apr, within MTD cutoff
            tx(date: 20260420, amount: -50000),  // Apr, after day 14 — excluded by MTD cutoff
            tx(date: 20260505, amount: -5000)    // current month
        ]
        let result = SpendingEngine.compute(meta: meta(mode: .average), transactions: transactions, today: asOf)
        #expect(result.currentSpentCents == 5000)
        // 3 prior months MTD: 10000 each (the 20260420 tx is past day 14), sum 30000, avg 30000/3 = 10000
        #expect(result.comparisonCents == 10000)
    }

    @Test func averageRangeSixMonths() {
        let transactions = [
            tx(date: 20251110, amount: -12000),
            tx(date: 20251210, amount: -12000),
            tx(date: 20260110, amount: -12000),
            tx(date: 20260210, amount: -6000),
            tx(date: 20260310, amount: -6000),
            tx(date: 20260410, amount: -6000)
        ]
        let range = SpendingAverageRange(mode: "last-n-months", months: 6)
        let result = SpendingEngine.compute(meta: meta(mode: .average, averageRange: range),
                                            transactions: transactions, today: asOf)
        #expect(result.comparisonCents == 9000)  // (3×12000 + 3×6000) / 6
    }

    @Test func averageRangeUnsupportedMonthsFallsBackToThree() {
        let transactions = [
            tx(date: 20251110, amount: -12000),
            tx(date: 20260210, amount: -6000),
            tx(date: 20260310, amount: -6000),
            tx(date: 20260410, amount: -6000)
        ]
        let range = SpendingAverageRange(mode: "last-n-months", months: 5)
        let result = SpendingEngine.compute(meta: meta(mode: .average, averageRange: range),
                                            transactions: transactions, today: asOf)
        #expect(result.comparisonCents == 6000)
    }

    @Test func averageRangeYearToDate() {
        let transactions = [
            tx(date: 20251210, amount: -99000),  // prior year — outside YTD
            tx(date: 20260110, amount: -8000),
            tx(date: 20260210, amount: -4000),
            tx(date: 20260310, amount: -4000),
            tx(date: 20260410, amount: -4000)
        ]
        let range = SpendingAverageRange(mode: "year-to-date", months: nil)
        let result = SpendingEngine.compute(meta: meta(mode: .average, averageRange: range),
                                            transactions: transactions, today: asOf)
        #expect(result.comparisonCents == 5000)  // (8000 + 4000×3) / 4 (Jan–Apr)
    }

    @Test func averageRangeAllTime() {
        // Earliest transaction is Dec 2025 → window Dec–Apr, 5 months.
        let transactions = [
            tx(date: 20251210, amount: -10000),
            tx(date: 20260505, amount: -100)
        ]
        let range = SpendingAverageRange(mode: "all-time", months: nil)
        let result = SpendingEngine.compute(meta: meta(mode: .average, averageRange: range),
                                            transactions: transactions, today: asOf)
        #expect(result.comparisonCents == 2000)  // 10000 / 5
    }

    @Test func singleMonthCompareTo() {
        let transactions = [
            tx(date: 20260301, amount: -7777),   // March
            tx(date: 20260501, amount: -100)     // current
        ]
        let result = SpendingEngine.compute(
            meta: meta(compareTo: "2026-03", mode: .singleMonth),
            transactions: transactions, today: asOf
        )
        #expect(result.comparisonCents == 7777)
    }

    @Test func budgetModeReturnsZeroComparison() {
        let result = SpendingEngine.compute(meta: meta(mode: .budget), transactions: [], today: asOf)
        #expect(result.comparisonCents == 0)
    }

    // Upstream spreads the compare month's budgeted total over its days and
    // accumulates through today's day bucket (spending-spreadsheet.ts
    // dailyBudget / SpendingCard.tsx todayDay).
    @Test func budgetModeProratesBudgetThroughToday() {
        let budgets = [
            BudgetAnalysisBudgetEntry(month: 202605, categoryId: "groceries", amountCents: 200000),
            BudgetAnalysisBudgetEntry(month: 202605, categoryId: "rent", amountCents: 110000),
            BudgetAnalysisBudgetEntry(month: 202604, categoryId: "rent", amountCents: 999999)  // other month — ignored
        ]
        let result = SpendingEngine.compute(meta: meta(mode: .budget), transactions: [],
                                            budgets: budgets, categories: budgetCategories,
                                            categoryGroups: budgetGroups, today: asOf)
        // 310000 over May's 31 days × 14 elapsed days
        #expect(result.comparisonCents == 140000)
    }

    @Test func budgetModeUsesFullMonthForPastCompare() {
        let budgets = [BudgetAnalysisBudgetEntry(month: 202603, categoryId: "rent", amountCents: 155000)]
        let result = SpendingEngine.compute(
            meta: meta(compare: "2026-03", isLive: false, mode: .budget),
            transactions: [], budgets: budgets, categories: budgetCategories,
            categoryGroups: budgetGroups, today: asOf
        )
        #expect(result.comparisonCents == 155000)
    }

    // getSpendingBudgetFilters: category conditions narrow the budgets too.
    @Test func budgetModeFiltersByCategoryConditions() {
        let budgets = [
            BudgetAnalysisBudgetEntry(month: 202605, categoryId: "groceries", amountCents: 100000),
            BudgetAnalysisBudgetEntry(month: 202605, categoryId: "rent", amountCents: 200000)
        ]
        let cond = WidgetRuleCondition.makeMock(op: "is", field: "category", stringValue: "groceries")
        let result = SpendingEngine.compute(meta: meta(conditions: [cond], mode: .budget),
                                            transactions: [], budgets: budgets,
                                            categories: budgetCategories,
                                            categoryGroups: budgetGroups, today: asOf)
        // 100000 / 31 × 14 = 45161.29…
        #expect(result.comparisonCents == 45161)
    }

    // getSpendingBudgetFilters: any unsupported category condition ⇒ budgets
    // are not narrowed at all.
    @Test func budgetModeUnsupportedCategoryConditionSkipsFilter() {
        let budgets = [
            BudgetAnalysisBudgetEntry(month: 202605, categoryId: "groceries", amountCents: 100000),
            BudgetAnalysisBudgetEntry(month: 202605, categoryId: "rent", amountCents: 200000)
        ]
        let cond = WidgetRuleCondition.makeMock(op: "gt", field: "category", stringValue: "x")
        let result = SpendingEngine.compute(meta: meta(conditions: [cond], mode: .budget),
                                            transactions: [], budgets: budgets,
                                            categories: budgetCategories,
                                            categoryGroups: budgetGroups, today: asOf)
        // 300000 / 31 × 14 = 135483.87…
        #expect(result.comparisonCents == 135484)
    }
}
