import Foundation
import Testing
@testable import Actuali

@MainActor
struct BudgetAnalysisEngineTests {

    private var asOf: Date {
        var c = DateComponents(); c.year = 2026; c.month = 5; c.day = 14
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    // Fixture mirrors upstream budgetDataQuery.test.ts / budget-analysis-spreadsheet.test.ts:
    // expense categories across two groups, plus a hidden expense and income categories.
    private let groups = [
        CategoryGroup(id: "gr-food", name: "Food", isIncome: false, hidden: false, sortOrder: 0, categories: []),
        CategoryGroup(id: "gr-fun", name: "Fun Money", isIncome: false, hidden: false, sortOrder: 1, categories: [])
    ]
    // Actuali.Category: the ObjC runtime also exports a `Category` type.
    private let groceries = Actuali.Category(id: "c-groceries", name: "Groceries", groupId: "gr-food", isIncome: false, hidden: false, sortOrder: 0)
    private let fun = Actuali.Category(id: "c-fun", name: "Dining Out", groupId: "gr-fun", isIncome: false, hidden: false, sortOrder: 1)
    private let hiddenExpense = Actuali.Category(id: "c-hidden", name: "Car Fund", groupId: "gr-fun", isIncome: false, hidden: true, sortOrder: 2)
    private let income = Actuali.Category(id: "c-income", name: "Salary", groupId: "gr-food", isIncome: true, hidden: false, sortOrder: 3)

    private var allCategories: [Actuali.Category] { [groceries, fun, hiddenExpense, income] }

    private func tx(date: Int, amount: Int, category: String?, account: String = "a1") -> Transaction {
        Transaction(
            id: UUID().uuidString,
            accountId: account, date: date, amount: amount,
            payeeId: nil, payeeName: nil, categoryId: category, categoryName: nil,
            notes: nil, cleared: false, reconciled: false,
            transferId: nil, isParent: false, parentId: nil,
            tombstone: false, sortOrder: nil, importedPayee: nil
        )
    }

    private func budget(_ month: Int, _ category: String, _ cents: Int) -> BudgetAnalysisBudgetEntry {
        BudgetAnalysisBudgetEntry(month: month, categoryId: category, amountCents: cents)
    }

    private func cond(_ field: String, _ op: String, json: String) -> WidgetRuleCondition {
        WidgetRuleCondition(op: op, field: field,
                            value: AnyCodable(rawJSON: Data(json.utf8)),
                            options: nil, customName: nil)
    }

    private func meta(
        conditions: [WidgetRuleCondition]? = nil,
        conditionsOp: String? = nil,
        start: String = "2026-01", end: String = "2026-03",
        graphType: String? = nil,
        showBalance: Bool? = nil,
        balanceOnly: Bool? = nil,
        showHiddenCategories: Bool? = nil
    ) -> BudgetAnalysisMeta {
        BudgetAnalysisMeta(
            name: nil, conditions: conditions, conditionsOp: conditionsOp,
            timeFrame: WidgetTimeFrame(start: start, end: end, mode: .static),
            interval: nil, graphType: graphType,
            showBalance: showBalance, balanceOnly: balanceOnly,
            showHiddenCategories: showHiddenCategories
        )
    }

    private func compute(
        _ meta: BudgetAnalysisMeta?,
        transactions: [Transaction] = [],
        budgets: [BudgetAnalysisBudgetEntry] = [],
        context: ConditionsFilter.Context = .empty
    ) -> BudgetAnalysisData {
        BudgetAnalysisEngine.compute(
            meta: meta, transactions: transactions, budgets: budgets,
            categories: allCategories, categoryGroups: groups,
            today: asOf, context: context
        )
    }

    // MARK: - Monthly budgeted vs spent, balance accumulation

    @Test func monthlyBudgetedVsSpentWithCarryover() {
        let result = compute(
            meta(),
            transactions: [
                tx(date: 20260110, amount: -30000, category: "c-groceries"),
                tx(date: 20260210, amount: -60000, category: "c-groceries"),
                tx(date: 20260310, amount: -20000, category: "c-groceries")
            ],
            budgets: [
                budget(202601, "c-groceries", 50000),
                budget(202602, "c-groceries", 50000),
                budget(202603, "c-groceries", 50000)
            ]
        )

        #expect(result.intervalData.map(\.month) == [202601, 202602, 202603])
        #expect(result.intervalData.map(\.budgetedCents) == [50000, 50000, 50000])
        // Spent stays negative, mirroring upstream's sum-amount cells.
        #expect(result.intervalData.map(\.spentCents) == [-30000, -60000, -20000])
        // Positive leftovers carry forward: 20000 into Feb, 10000 into Mar.
        #expect(result.intervalData.map(\.balanceCents) == [20000, 10000, 40000])
        #expect(result.intervalData.map(\.overspendingAdjustmentCents) == [0, 0, 0])
        #expect(result.totalBudgetedCents == 150000)
        #expect(result.totalSpentCents == -110000)
    }

    @Test func overspendingZeroesOutAndSurfacesNextMonth() {
        let result = compute(
            meta(start: "2026-01", end: "2026-02"),
            transactions: [tx(date: 20260105, amount: -15000, category: "c-groceries")],
            budgets: [
                budget(202601, "c-groceries", 10000),
                budget(202602, "c-groceries", 10000)
            ]
        )

        #expect(result.intervalData.map(\.balanceCents) == [-5000, 10000])
        // The negative leftover doesn't carry (no carryover flag); it shows
        // up as the next month's overspending adjustment instead.
        #expect(result.intervalData.map(\.overspendingAdjustmentCents) == [0, 5000])
    }

    @Test func earlierMonthsSeedTheRunningBalance() {
        // Range starts in Feb; January's data initializes the carryover the
        // way upstream reads the previous month's leftover cells. January's
        // fun overspending is zeroed and must not leak into the range.
        let result = compute(
            meta(start: "2026-02", end: "2026-02"),
            transactions: [
                tx(date: 20260110, amount: -4000, category: "c-groceries"),
                tx(date: 20260112, amount: -3000, category: "c-fun")
            ],
            budgets: [budget(202601, "c-groceries", 10000)]
        )

        #expect(result.intervalData.count == 1)
        #expect(result.intervalData[0].budgetedCents == 0)
        #expect(result.intervalData[0].spentCents == 0)
        #expect(result.intervalData[0].balanceCents == 6000)
        #expect(result.intervalData[0].overspendingAdjustmentCents == 0)
    }

    // MARK: - Category conditions (mirrors budgetDataQuery.test.ts)

    @Test func categoryConditionNarrowsBudgetsAndTransactions() {
        let result = compute(
            meta(conditions: [cond("category", "is", json: "\"c-groceries\"")],
                 start: "2026-01", end: "2026-01"),
            transactions: [
                tx(date: 20260105, amount: -5000, category: "c-groceries"),
                tx(date: 20260106, amount: -7000, category: "c-fun")
            ],
            budgets: [
                budget(202601, "c-groceries", 10000),
                budget(202601, "c-fun", 99900)
            ]
        )

        #expect(result.intervalData.map(\.budgetedCents) == [10000])
        #expect(result.intervalData.map(\.spentCents) == [-5000])
    }

    @Test func categoryGroupConditionFiltersByGroup() {
        let result = compute(
            meta(conditions: [cond("category_group", "is", json: "\"gr-food\"")],
                 start: "2026-01", end: "2026-01"),
            transactions: [
                tx(date: 20260105, amount: -5000, category: "c-groceries"),
                tx(date: 20260106, amount: -7000, category: "c-fun")
            ],
            budgets: [
                budget(202601, "c-groceries", 10000),
                budget(202601, "c-fun", 99900)
            ]
        )

        #expect(result.intervalData.map(\.budgetedCents) == [10000])
        #expect(result.intervalData.map(\.spentCents) == [-5000])
    }

    @Test func categoryGroupOneOfAndAndCombination() {
        // oneOf on group
        let oneOf = compute(
            meta(conditions: [cond("category_group", "oneOf", json: "[\"gr-fun\"]")],
                 start: "2026-01", end: "2026-01"),
            budgets: [
                budget(202601, "c-groceries", 10000),
                budget(202601, "c-fun", 20000)
            ]
        )
        #expect(oneOf.intervalData.map(\.budgetedCents) == [20000])

        // AND of category_group + category (upstream: intersection)
        let combined = compute(
            meta(conditions: [
                cond("category_group", "is", json: "\"gr-food\""),
                cond("category", "is", json: "\"c-groceries\"")
            ], start: "2026-01", end: "2026-01"),
            budgets: [
                budget(202601, "c-groceries", 10000),
                budget(202601, "c-fun", 20000)
            ]
        )
        #expect(combined.intervalData.map(\.budgetedCents) == [10000])
    }

    @Test func textOperatorsMatchGroupNames() {
        // Upstream: contains matches against the group's name, not its UUID.
        let result = compute(
            meta(conditions: [cond("category_group", "contains", json: "\"fun\"")],
                 start: "2026-01", end: "2026-01"),
            budgets: [
                budget(202601, "c-groceries", 10000),
                budget(202601, "c-fun", 20000)
            ]
        )
        #expect(result.intervalData.map(\.budgetedCents) == [20000])
    }

    @Test func unsupportedConditionDisablesCategoryFilter() {
        // Upstream isSupportedCategoryCondition: an op like "gt" (or a
        // mistyped value) means no category filtering at all — even when
        // other conditions are supported.
        let result = compute(
            meta(conditions: [
                cond("category", "is", json: "\"c-groceries\""),
                cond("category", "gt", json: "\"x\"")
            ], start: "2026-01", end: "2026-01"),
            transactions: [
                tx(date: 20260105, amount: -5000, category: "c-groceries"),
                tx(date: 20260106, amount: -7000, category: "c-fun")
            ],
            budgets: [
                budget(202601, "c-groceries", 10000),
                budget(202601, "c-fun", 99900)
            ]
        )

        #expect(result.intervalData.map(\.budgetedCents) == [109900])
        #expect(result.intervalData.map(\.spentCents) == [-12000])
    }

    @Test func nonCategoryConditionsAreIgnored() {
        let result = compute(
            meta(conditions: [cond("amount", "gt", json: "100")],
                 start: "2026-01", end: "2026-01"),
            budgets: [
                budget(202601, "c-groceries", 10000),
                budget(202601, "c-fun", 20000)
            ]
        )
        #expect(result.intervalData.map(\.budgetedCents) == [30000])
    }

    // MARK: - Hidden and income categories (mirrors budget-analysis-spreadsheet.test.ts)

    @Test func hiddenCategoriesExcludedUnlessRequested() {
        let transactions = [
            tx(date: 20260105, amount: -5000, category: "c-groceries"),
            tx(date: 20260106, amount: -1000, category: "c-hidden")
        ]
        let budgets = [
            budget(202601, "c-groceries", 10000),
            budget(202601, "c-hidden", 20000)
        ]

        let withoutHidden = compute(meta(start: "2026-01", end: "2026-01"),
                                    transactions: transactions, budgets: budgets)
        #expect(withoutHidden.intervalData.map(\.budgetedCents) == [10000])
        #expect(withoutHidden.intervalData.map(\.spentCents) == [-5000])

        let withHidden = compute(meta(start: "2026-01", end: "2026-01", showHiddenCategories: true),
                                 transactions: transactions, budgets: budgets)
        #expect(withHidden.intervalData.map(\.budgetedCents) == [30000])
        #expect(withHidden.intervalData.map(\.spentCents) == [-6000])
    }

    @Test func incomeCategoriesAlwaysExcluded() {
        let result = compute(
            meta(start: "2026-01", end: "2026-01", showHiddenCategories: true),
            transactions: [tx(date: 20260105, amount: 100000, category: "c-income")],
            budgets: [budget(202601, "c-income", 50000)]
        )
        #expect(result.intervalData.map(\.budgetedCents) == [0])
        #expect(result.intervalData.map(\.spentCents) == [0])
    }

    @Test func offBudgetAccountsExcludedFromSpending() {
        let result = compute(
            meta(start: "2026-01", end: "2026-01"),
            transactions: [
                tx(date: 20260105, amount: -5000, category: "c-groceries"),
                tx(date: 20260106, amount: -9000, category: "c-groceries", account: "a-off")
            ],
            context: ConditionsFilter.Context(offBudgetAccountIds: ["a-off"], accountNames: [:])
        )
        #expect(result.intervalData.map(\.spentCents) == [-5000])
    }

    // MARK: - Defaults

    @Test func defaultTimeFrameIsTrailingSixMonthsAndDisplayDefaultsMatchUpstream() {
        let result = compute(nil)
        #expect(result.intervalData.map(\.month) == [202512, 202601, 202602, 202603, 202604, 202605])
        #expect(result.graphType == .bar)
        #expect(result.showBalance == true)
        #expect(result.balanceOnly == false)
    }

    @Test func displayFlagsComeFromMeta() {
        let result = compute(meta(graphType: "Line", showBalance: false, balanceOnly: true))
        #expect(result.graphType == .line)
        #expect(result.showBalance == false)
        #expect(result.balanceOnly == true)
    }
}
