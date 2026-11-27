import Foundation
import Testing
@testable import Actuali

struct WidgetSnapshotTests {
    private func makeStore() throws -> WidgetSnapshotStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WidgetSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return WidgetSnapshotStore(containerURL: dir)
    }

    private func sampleSnapshot() -> WidgetSnapshot {
        WidgetSnapshot(
            month: "2026-08",
            generatedAt: Date(timeIntervalSince1970: 1_750_000_000),
            balancesHidden: false,
            categories: [
                WidgetCategoryBalance(id: "a", name: "Dining Out", available: 12345, formattedAvailable: "$123.45"),
                WidgetCategoryBalance(id: "b", name: "Groceries", available: -2000, formattedAvailable: "-$20.00"),
                WidgetCategoryBalance(id: "c", name: "Fun Money", available: 0, formattedAvailable: "$0.00"),
            ]
        )
    }

    // MARK: - Store

    @Test func readReturnsNilWhenNoSnapshotWritten() throws {
        let store = try makeStore()

        #expect(store.read() == nil)
    }

    @Test func writeThenReadRoundTrips() throws {
        let store = try makeStore()
        let snapshot = sampleSnapshot()

        try store.write(snapshot)

        #expect(store.read() == snapshot)
    }

    @Test func writeReplacesPreviousSnapshot() throws {
        let store = try makeStore()
        try store.write(sampleSnapshot())
        let newer = WidgetSnapshot(
            month: "2026-09",
            generatedAt: Date(timeIntervalSince1970: 1_760_000_000),
            balancesHidden: true,
            categories: []
        )

        try store.write(newer)

        #expect(store.read() == newer)
    }

    @Test func clearRemovesSnapshot() throws {
        let store = try makeStore()
        try store.write(sampleSnapshot())

        store.clear()

        #expect(store.read() == nil)
    }

    @Test func readReturnsNilForCorruptFile() throws {
        let store = try makeStore()

        try Data("not json".utf8).write(to: store.fileURL)

        #expect(store.read() == nil)
    }

    // MARK: - Month staleness

    @Test func snapshotIsCurrentOnlyForItsOwnMonth() {
        let calendar = Calendar.current
        let inAugust = calendar.date(from: DateComponents(year: 2026, month: 8, day: 15))!
        let inSeptember = calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!

        let snapshot = sampleSnapshot()

        #expect(snapshot.isForMonth(containing: inAugust))
        #expect(!snapshot.isForMonth(containing: inSeptember))
    }

    // MARK: - Category selection

    @Test func selectionPreservesChosenOrderAndDropsUnknownIds() {
        let picked = sampleSnapshot().categories(matching: ["c", "missing", "a"], limit: 4)

        #expect(picked.map(\.id) == ["c", "a"])
    }

    @Test func emptySelectionFallsBackToFirstCategories() {
        let picked = sampleSnapshot().categories(matching: [], limit: 2)

        #expect(picked.map(\.id) == ["a", "b"])
    }

    @Test func selectionIsCappedAtLimit() {
        let picked = sampleSnapshot().categories(matching: ["a", "b", "c"], limit: 2)

        #expect(picked.map(\.id) == ["a", "b"])
    }

    // MARK: - Large / Extra Large Portrait limits (#862)

    // Mirror CategoryBalanceProvider's per-family limits; the provider lives
    // in the widget extension, out of this test target's reach.
    private let largeLimit = 8
    private let extraLargePortraitLimit = 12

    private func manyCategoriesSnapshot(count: Int = 15) -> WidgetSnapshot {
        WidgetSnapshot(
            month: "2026-08",
            generatedAt: Date(timeIntervalSince1970: 1_750_000_000),
            balancesHidden: false,
            categories: (0..<count).map {
                WidgetCategoryBalance(id: "c\($0)", name: "Category \($0)", available: $0 * 100, formattedAvailable: "$\($0).00")
            }
        )
    }

    @Test(arguments: [0, 1, 4, 7, 8])
    func largeShowsChosenCategoriesUpToEight(chosen: Int) {
        let ids = (0..<chosen).reversed().map { "c\($0)" }

        let picked = manyCategoriesSnapshot().categories(matching: ids, limit: largeLimit)

        // No selection falls back to the budget's first eight.
        #expect(picked.map(\.id) == (chosen == 0 ? (0..<8).map { "c\($0)" } : ids))
    }

    @Test func largeCapsAtEightWhenMoreChosen() {
        let ids = (0..<12).map { "c\($0)" }

        let picked = manyCategoriesSnapshot().categories(matching: ids, limit: largeLimit)

        #expect(picked.map(\.id) == Array(ids.prefix(8)))
    }

    @Test(arguments: [0, 1, 6, 11, 12])
    func extraLargePortraitShowsChosenCategoriesUpToTwelve(chosen: Int) {
        let ids = (0..<chosen).reversed().map { "c\($0)" }

        let picked = manyCategoriesSnapshot().categories(matching: ids, limit: extraLargePortraitLimit)

        #expect(picked.map(\.id) == (chosen == 0 ? (0..<12).map { "c\($0)" } : ids))
    }

    @Test func extraLargePortraitCapsAtTwelveWhenMoreChosen() {
        let ids = (0..<15).map { "c\($0)" }

        let picked = manyCategoriesSnapshot().categories(matching: ids, limit: extraLargePortraitLimit)

        #expect(picked.map(\.id) == Array(ids.prefix(12)))
    }

    @Test func fewerCategoriesThanLimitShowsOnlyWhatExists() {
        let snapshot = manyCategoriesSnapshot(count: 3)

        #expect(snapshot.categories(matching: [], limit: largeLimit).map(\.id) == ["c0", "c1", "c2"])
        #expect(snapshot.categories(matching: [], limit: extraLargePortraitLimit).map(\.id) == ["c0", "c1", "c2"])
        #expect(snapshot.categories(matching: ["c2", "c0"], limit: extraLargePortraitLimit).map(\.id) == ["c2", "c0"])
    }

    @Test func limitAppliesAfterDroppingUnknownIds() {
        // Unknown IDs interleaved ahead of each real one: capping before
        // matching would leave only half the rows.
        let known = (0..<15).map { "c\($0)" }
        let ids = known.flatMap { ["deleted-\($0)", $0] }
        let snapshot = manyCategoriesSnapshot()

        #expect(snapshot.categories(matching: ids, limit: largeLimit).map(\.id) == Array(known.prefix(8)))
        #expect(snapshot.categories(matching: ids, limit: extraLargePortraitLimit).map(\.id) == Array(known.prefix(12)))
    }

    @Test @MainActor func hiddenBalancesMaskEveryLargeAndExtraLargeAmount() throws {
        let budgetStore = BudgetStore.previewInstance()
        let store = try makeStore()
        budgetStore.widgetSnapshotStore = store
        budgetStore.widgetBudgetMonth = BudgetMonth(
            month: "2026-08",
            categoryBudgets: (0..<15).map { makeBudget(id: "c\($0)", name: "Category \($0)", month: "2026-08") }
        )
        budgetStore.hideBalances = true
        defer { budgetStore.hideBalances = false }

        let snapshot = try #require(store.read())

        #expect(snapshot.balancesHidden)
        for limit in [largeLimit, extraLargePortraitLimit] {
            let shown = snapshot.categories(matching: [], limit: limit)
            #expect(shown.count == limit)
            #expect(shown.allSatisfy { $0.formattedAvailable == BudgetStore.hiddenBalanceText })
        }
    }

    // AccountBalanceProvider uses the same per-family limits as categories.

    private func manyAccountsSnapshot(count: Int = 15) -> WidgetSnapshot {
        var snapshot = manyCategoriesSnapshot(count: 0)
        snapshot.accounts = (0..<count).map {
            WidgetAccountBalance(id: "a\($0)", name: "Account \($0)", balance: $0 * 100, formattedBalance: "$\($0).00", type: "checking", offBudget: false)
        }
        return snapshot
    }

    @Test(arguments: [0, 1, 4, 7, 8])
    func largeShowsChosenAccountsUpToEight(chosen: Int) {
        let ids = (0..<chosen).reversed().map { "a\($0)" }

        let picked = manyAccountsSnapshot().accounts(matching: ids, limit: largeLimit)

        // No selection falls back to the first eight on-budget accounts.
        #expect(picked.map(\.id) == (chosen == 0 ? (0..<8).map { "a\($0)" } : ids))
    }

    @Test func largeCapsAccountsAtEightWhenMoreChosen() {
        let ids = (0..<12).map { "a\($0)" }

        let picked = manyAccountsSnapshot().accounts(matching: ids, limit: largeLimit)

        #expect(picked.map(\.id) == Array(ids.prefix(8)))
    }

    @Test(arguments: [0, 1, 6, 11, 12])
    func extraLargePortraitShowsChosenAccountsUpToTwelve(chosen: Int) {
        let ids = (0..<chosen).reversed().map { "a\($0)" }

        let picked = manyAccountsSnapshot().accounts(matching: ids, limit: extraLargePortraitLimit)

        #expect(picked.map(\.id) == (chosen == 0 ? (0..<12).map { "a\($0)" } : ids))
    }

    @Test func extraLargePortraitCapsAccountsAtTwelveWhenMoreChosen() {
        let ids = (0..<15).map { "a\($0)" }

        let picked = manyAccountsSnapshot().accounts(matching: ids, limit: extraLargePortraitLimit)

        #expect(picked.map(\.id) == Array(ids.prefix(12)))
    }

    @Test func fewerAccountsThanLimitShowsOnlyWhatExists() {
        let snapshot = manyAccountsSnapshot(count: 3)

        #expect(snapshot.accounts(matching: [], limit: largeLimit).map(\.id) == ["a0", "a1", "a2"])
        #expect(snapshot.accounts(matching: [], limit: extraLargePortraitLimit).map(\.id) == ["a0", "a1", "a2"])
        #expect(snapshot.accounts(matching: ["a2", "a0"], limit: extraLargePortraitLimit).map(\.id) == ["a2", "a0"])
    }

    @Test func accountLimitAppliesAfterDroppingUnknownIds() {
        let known = (0..<15).map { "a\($0)" }
        let ids = known.flatMap { ["deleted-\($0)", $0] }
        let snapshot = manyAccountsSnapshot()

        #expect(snapshot.accounts(matching: ids, limit: largeLimit).map(\.id) == Array(known.prefix(8)))
        #expect(snapshot.accounts(matching: ids, limit: extraLargePortraitLimit).map(\.id) == Array(known.prefix(12)))
    }

    @Test @MainActor func hiddenBalancesMaskEveryLargeAndExtraLargeAccount() throws {
        let budgetStore = BudgetStore.previewInstance()
        let store = try makeStore()
        budgetStore.widgetSnapshotStore = store
        budgetStore.widgetBudgetMonth = BudgetMonth(month: "2026-08", categoryBudgets: [])
        budgetStore.accounts = (0..<15).map {
            Account(id: "a\($0)", name: "Account \($0)", type: .checking, offBudget: false, closed: false, sortOrder: $0, balance: 10000)
        }
        budgetStore.hideBalances = true
        defer { budgetStore.hideBalances = false }

        let snapshot = try #require(store.read())

        #expect(snapshot.balancesHidden)
        for limit in [largeLimit, extraLargePortraitLimit] {
            let shown = snapshot.accounts(matching: [], limit: limit)
            #expect(shown.count == limit)
            #expect(shown.allSatisfy { $0.formattedBalance == BudgetStore.hiddenBalanceText })
        }
    }

    // NetWorthProvider has no account picker; it always takes the fallback
    // rows at these per-family limits.
    private let netWorthMediumLimit = 3
    private let netWorthLargeLimit = 6
    private let netWorthExtraLargePortraitLimit = 10

    @Test func netWorthShowsFirstAccountsUpToFamilyLimit() {
        let snapshot = manyAccountsSnapshot()

        #expect(snapshot.accounts(matching: [], limit: netWorthMediumLimit).map(\.id) == ["a0", "a1", "a2"])
        #expect(snapshot.accounts(matching: [], limit: netWorthLargeLimit).map(\.id) == (0..<6).map { "a\($0)" })
        #expect(snapshot.accounts(matching: [], limit: netWorthExtraLargePortraitLimit).map(\.id) == (0..<10).map { "a\($0)" })
    }

    @Test func netWorthFewerAccountsThanLimitShowsOnlyWhatExists() {
        let snapshot = manyAccountsSnapshot(count: 2)

        for limit in [netWorthMediumLimit, netWorthLargeLimit, netWorthExtraLargePortraitLimit] {
            #expect(snapshot.accounts(matching: [], limit: limit).map(\.id) == ["a0", "a1"])
        }
    }

    @Test func netWorthRowsFollowSortOrderAndSkipOffBudget() {
        let accounts = [
            Account(id: "invest", name: "Brokerage", type: .investment, offBudget: true, closed: false, sortOrder: 0, balance: 900_000),
            Account(id: "savings", name: "Savings", type: .savings, offBudget: false, closed: false, sortOrder: 2, balance: 500_000),
            Account(id: "checking", name: "Checking", type: .checking, offBudget: false, closed: false, sortOrder: 1, balance: 250_000),
        ]

        let snapshot = WidgetSnapshot.make(
            from: [], month: "2026-08", balancesHidden: false, generatedAt: Date(), format: { "$\($0)" }, accounts: accounts
        )

        // The total still counts the off-budget account the rows leave out.
        #expect(snapshot.netWorth == 1_650_000)
        #expect(snapshot.accounts(matching: [], limit: netWorthMediumLimit).map(\.id) == ["checking", "savings"])
    }

    /// The case NetWorthWidgetView's "No accounts to show" line covers: a
    /// total to show but no on-budget rows under it.
    @Test func netWorthWithOnlyOffBudgetAccountsHasTotalButNoRows() {
        let accounts = [
            Account(id: "invest", name: "Brokerage", type: .investment, offBudget: true, closed: false, sortOrder: 0, balance: 900_000),
        ]

        let snapshot = WidgetSnapshot.make(
            from: [], month: "2026-08", balancesHidden: false, generatedAt: Date(), format: { "$\($0)" }, accounts: accounts
        )

        #expect(snapshot.formattedNetWorth != nil)
        for limit in [netWorthMediumLimit, netWorthLargeLimit, netWorthExtraLargePortraitLimit] {
            #expect(snapshot.accounts(matching: [], limit: limit).isEmpty)
        }
    }

    @Test @MainActor func hiddenBalancesMaskNetWorthTotalAndEveryRow() throws {
        let budgetStore = BudgetStore.previewInstance()
        let store = try makeStore()
        budgetStore.widgetSnapshotStore = store
        budgetStore.widgetBudgetMonth = BudgetMonth(month: "2026-08", categoryBudgets: [])
        budgetStore.accounts = (0..<15).map {
            Account(id: "a\($0)", name: "Account \($0)", type: .checking, offBudget: false, closed: false, sortOrder: $0, balance: 10000)
        }
        budgetStore.hideBalances = true
        defer { budgetStore.hideBalances = false }

        let snapshot = try #require(store.read())

        #expect(snapshot.balancesHidden)
        #expect(snapshot.formattedNetWorth == BudgetStore.hiddenBalanceText)
        for limit in [netWorthMediumLimit, netWorthLargeLimit, netWorthExtraLargePortraitLimit] {
            let shown = snapshot.accounts(matching: [], limit: limit)
            #expect(shown.count == limit)
            #expect(shown.allSatisfy { $0.formattedBalance == BudgetStore.hiddenBalanceText })
        }
    }

    // ToBeBudgetedProvider's per-family unbudgeted-category limits; Medium
    // shows the budgeted/spending summary instead of rows.
    private let toBudgetLargeLimit = 5
    private let toBudgetExtraLargePortraitLimit = 8

    /// Even indices have nothing budgeted this month, odd ones do.
    private func mixedBudgetedSnapshot(count: Int = 20) -> WidgetSnapshot {
        WidgetSnapshot(
            month: "2026-08",
            generatedAt: Date(timeIntervalSince1970: 1_750_000_000),
            balancesHidden: false,
            categories: (0..<count).map {
                WidgetCategoryBalance(
                    id: "c\($0)", name: "Category \($0)", available: $0 * 100, formattedAvailable: "$\($0).00",
                    budgeted: $0.isMultiple(of: 2) ? 0 : 5000
                )
            }
        )
    }

    @Test func toBudgetMediumSummaryCarriesBudgetedAndSpentTotals() {
        let budgeted = CategoryBudget(
            month: "2026-08", categoryId: "c1", categoryName: "Groceries",
            groupId: "g1", groupName: "Everyday", groupSortOrder: 0, categorySortOrder: 0,
            budgeted: 200_000, spent: -150_000, available: 50000, carryover: 0
        )
        let month = BudgetMonth(month: "2026-08", categoryBudgets: [budgeted], toBudget: 45000)

        let snapshot = WidgetSnapshot.make(
            from: [budgeted], month: "2026-08", balancesHidden: false, generatedAt: Date(),
            format: { "$\($0)" }, budgetMonth: month
        )

        #expect(snapshot.formattedToBudget == "$45000")
        #expect(snapshot.formattedTotalBudgeted == "$200000")
        #expect(snapshot.formattedTotalSpent == "$-150000")
        // Top Spending's header reads positive, like its Spent column.
        #expect(snapshot.formattedTotalSpending == "$150000")
    }

    @Test func toBudgetTrackingBudgetHasNoTotalButKeepsSummary() {
        let month = BudgetMonth(month: "2026-08", categoryBudgets: [], toBudget: nil)

        let snapshot = WidgetSnapshot.make(
            from: [], month: "2026-08", balancesHidden: false, generatedAt: Date(),
            format: { "$\($0)" }, budgetMonth: month
        )

        #expect(snapshot.toBudget == nil)
        #expect(snapshot.formattedToBudget == nil)
        #expect(snapshot.formattedTotalBudgeted == "$0")
        #expect(snapshot.formattedTotalSpent == "$0")
    }

    @Test func makeCarriesEachCategoryBudgetedAmount() {
        // Unbudgeted means nothing assigned this month, not a zero balance:
        // carryover can leave an unbudgeted category with money, and spending
        // can drain a budgeted one to zero.
        let budgets = [
            CategoryBudget(
                month: "2026-08", categoryId: "carry", categoryName: "Carryover Only",
                groupId: "g1", groupName: "Everyday", groupSortOrder: 0, categorySortOrder: 0,
                budgeted: 0, spent: 0, available: 3000, carryover: 3000
            ),
            CategoryBudget(
                month: "2026-08", categoryId: "drained", categoryName: "Drained",
                groupId: "g1", groupName: "Everyday", groupSortOrder: 0, categorySortOrder: 1,
                budgeted: 5000, spent: -5000, available: 0, carryover: 0
            ),
        ]

        let snapshot = WidgetSnapshot.make(
            from: budgets, month: "2026-08", balancesHidden: false, generatedAt: Date(), format: { "$\($0)" }
        )

        #expect(snapshot.categories.map(\.budgeted) == [0, 5000])
        #expect(snapshot.unbudgetedCategories(limit: toBudgetLargeLimit).map(\.id) == ["carry"])
    }

    @Test func toBudgetLargeShowsFirstFiveUnbudgetedCategories() {
        let picked = mixedBudgetedSnapshot().unbudgetedCategories(limit: toBudgetLargeLimit)

        #expect(picked.map(\.id) == ["c0", "c2", "c4", "c6", "c8"])
    }

    @Test func toBudgetExtraLargePortraitShowsFirstEightUnbudgetedCategories() {
        let picked = mixedBudgetedSnapshot().unbudgetedCategories(limit: toBudgetExtraLargePortraitLimit)

        #expect(picked.map(\.id) == (0..<8).map { "c\($0 * 2)" })
    }

    @Test func toBudgetFewerUnbudgetedThanLimitShowsOnlyWhatExists() {
        let snapshot = mixedBudgetedSnapshot(count: 5)

        for limit in [toBudgetLargeLimit, toBudgetExtraLargePortraitLimit] {
            #expect(snapshot.unbudgetedCategories(limit: limit).map(\.id) == ["c0", "c2", "c4"])
        }
    }

    @Test func toBudgetSkipsCategoriesWithUnknownBudgetedAmount() {
        // A snapshot written before `budgeted` existed decodes it as nil;
        // nil is unknown, not unbudgeted.
        let snapshot = sampleSnapshot()

        #expect(snapshot.unbudgetedCategories(limit: toBudgetExtraLargePortraitLimit).isEmpty)
    }

    @Test @MainActor func hiddenBalancesMaskToBudgetSummaryAndEveryUnbudgetedRow() throws {
        let budgetStore = BudgetStore.previewInstance()
        let store = try makeStore()
        budgetStore.widgetSnapshotStore = store
        budgetStore.widgetBudgetMonth = BudgetMonth(
            month: "2026-08",
            categoryBudgets: (0..<15).map {
                CategoryBudget(
                    month: "2026-08", categoryId: "c\($0)", categoryName: "Category \($0)",
                    groupId: "g1", groupName: "Everyday", groupSortOrder: 0, categorySortOrder: Double($0),
                    budgeted: 0, spent: -500, available: 2500, carryover: 3000
                )
            },
            toBudget: 45000
        )
        budgetStore.hideBalances = true
        defer { budgetStore.hideBalances = false }

        let snapshot = try #require(store.read())

        #expect(snapshot.balancesHidden)
        #expect(snapshot.formattedToBudget == BudgetStore.hiddenBalanceText)
        #expect(snapshot.formattedTotalBudgeted == BudgetStore.hiddenBalanceText)
        #expect(snapshot.formattedTotalSpent == BudgetStore.hiddenBalanceText)
        #expect(snapshot.formattedTotalSpending == BudgetStore.hiddenBalanceText)
        for limit in [toBudgetLargeLimit, toBudgetExtraLargePortraitLimit] {
            let shown = snapshot.unbudgetedCategories(limit: limit)
            #expect(shown.count == limit)
            #expect(shown.allSatisfy { $0.formattedAvailable == BudgetStore.hiddenBalanceText })
        }
    }

    // SpendingSummaryProvider's per-family category-row limits; Small and
    // Medium show totals only.
    private let spendingLargeLimit = 5
    private let spendingExtraLargePortraitLimit = 8

    private func spendingSnapshot(spent: Int?, budgeted: Int?, balancesHidden: Bool = false) -> WidgetSnapshot {
        var snapshot = WidgetSnapshot(
            month: "2026-08", generatedAt: Date(timeIntervalSince1970: 1_750_000_000),
            balancesHidden: balancesHidden, categories: []
        )
        snapshot.totalSpent = spent
        snapshot.totalBudgeted = budgeted
        return snapshot
    }

    @Test func spendingLargeAndExtraLargeShowFirstCategoriesInBudgetOrder() {
        let snapshot = manyCategoriesSnapshot()

        #expect(snapshot.categories(matching: [], limit: spendingLargeLimit).map(\.id) == (0..<5).map { "c\($0)" })
        #expect(snapshot.categories(matching: [], limit: spendingExtraLargePortraitLimit).map(\.id) == (0..<8).map { "c\($0)" })
    }

    @Test func spendingFewerCategoriesThanLimitShowsOnlyWhatExists() {
        let snapshot = manyCategoriesSnapshot(count: 3)

        for limit in [spendingLargeLimit, spendingExtraLargePortraitLimit] {
            #expect(snapshot.categories(matching: [], limit: limit).map(\.id) == ["c0", "c1", "c2"])
        }
    }

    @Test func spentFractionIsShareOfBudgetCappedAtOne() {
        #expect(spendingSnapshot(spent: -80000, budgeted: 320_000).spentFraction == 0.25)
        #expect(spendingSnapshot(spent: -320_000, budgeted: 320_000).spentFraction == 1.0)
        #expect(spendingSnapshot(spent: -500_000, budgeted: 320_000).spentFraction == 1.0)
    }

    @Test func spentFractionIsZeroWithoutAmountsToMeasure() {
        #expect(spendingSnapshot(spent: nil, budgeted: 320_000).spentFraction == 0)
        #expect(spendingSnapshot(spent: -80000, budgeted: nil).spentFraction == 0)
        #expect(spendingSnapshot(spent: -80000, budgeted: 0).spentFraction == 0)
        #expect(spendingSnapshot(spent: nil, budgeted: nil).spentFraction == 0)
    }

    @Test func overbudgetOnlyWhenSpendingExceedsBudget() {
        #expect(spendingSnapshot(spent: -320_001, budgeted: 320_000).isOverbudget)
        #expect(!spendingSnapshot(spent: -320_000, budgeted: 320_000).isOverbudget)
        #expect(!spendingSnapshot(spent: -80000, budgeted: 320_000).isOverbudget)
        #expect(!spendingSnapshot(spent: nil, budgeted: 320_000).isOverbudget)
        #expect(!spendingSnapshot(spent: -80000, budgeted: nil).isOverbudget)
        #expect(!spendingSnapshot(spent: -80000, budgeted: 0).isOverbudget)
    }

    @Test func hiddenBalancesNeutralizeSpendingProgress() {
        // The raw cents still ride along when hidden; the bar's fill and red
        // tint would leak the ratio the masked text hides.
        let snapshot = spendingSnapshot(spent: -500_000, budgeted: 320_000, balancesHidden: true)

        #expect(snapshot.spentFraction == 0)
        #expect(!snapshot.isOverbudget)
    }

    @Test @MainActor func hiddenBalancesMaskSpendingTotalsAndEveryLargeAndExtraLargeRow() throws {
        let budgetStore = BudgetStore.previewInstance()
        let store = try makeStore()
        budgetStore.widgetSnapshotStore = store
        budgetStore.widgetBudgetMonth = BudgetMonth(
            month: "2026-08",
            categoryBudgets: (0..<15).map { makeBudget(id: "c\($0)", name: "Category \($0)", month: "2026-08") },
            incomeCategories: [
                IncomeCategory(
                    month: "2026-08", categoryId: "i1", categoryName: "Salary",
                    groupName: "Income", sortOrder: 0, budgeted: 0, received: 300_000
                ),
            ]
        )
        budgetStore.hideBalances = true
        defer { budgetStore.hideBalances = false }

        let snapshot = try #require(store.read())

        #expect(snapshot.balancesHidden)
        #expect(snapshot.formattedTotalSpent == BudgetStore.hiddenBalanceText)
        #expect(snapshot.formattedTotalBudgeted == BudgetStore.hiddenBalanceText)
        #expect(snapshot.formattedTotalIncome == BudgetStore.hiddenBalanceText)
        #expect(snapshot.spentFraction == 0)
        for limit in [spendingLargeLimit, spendingExtraLargePortraitLimit] {
            let shown = snapshot.categories(matching: [], limit: limit)
            #expect(shown.count == limit)
            #expect(shown.allSatisfy { $0.formattedAvailable == BudgetStore.hiddenBalanceText })
        }
    }

    @Test func relativeDateUsesExplicitLocale() {
        let reference = Date(timeIntervalSince1970: 1_750_000_000)
        let date = reference.addingTimeInterval(-2 * 86400)

        #expect(WidgetDateFormatting.relative(
            date,
            relativeTo: reference,
            locale: Locale(identifier: "en_US")
        ) == "2 days ago")
        #expect(WidgetDateFormatting.relative(
            date,
            relativeTo: reference,
            locale: Locale(identifier: "fr_FR")
        ) == "il y a 2 jours")
    }

    /// The gallery's `.sample` entries are dated `.now`, which numeric style
    /// renders as "in 0 seconds"; a future date reads the same as now.
    @Test(arguments: [0.0, 0.3, 300])
    func relativeDateNeverReadsAsFuture(offset: TimeInterval) {
        let reference = Date(timeIntervalSince1970: 1_750_000_000)

        #expect(WidgetDateFormatting.relative(
            reference.addingTimeInterval(offset),
            relativeTo: reference,
            locale: Locale(identifier: "en_US")
        ) == "now")
    }

    // MARK: - BudgetStore publishing

    private func makeBudget(id: String, name: String, month: String) -> CategoryBudget {
        CategoryBudget(
            month: month, categoryId: id, categoryName: name,
            groupId: "g1", groupName: "Everyday", groupSortOrder: 0, categorySortOrder: 0,
            budgeted: 10000, spent: -5000, available: 5000, carryover: 0
        )
    }

    @Test @MainActor func publishUsesWidgetMonthNotBrowsedMonth() throws {
        let budgetStore = BudgetStore.previewInstance()
        let store = try makeStore()
        budgetStore.widgetSnapshotStore = store
        // The user is browsing January's history while the calendar says August.
        budgetStore.currentBudgetMonth = BudgetMonth(
            month: "2026-01", categoryBudgets: [makeBudget(id: "old", name: "Old", month: "2026-01")]
        )
        budgetStore.widgetBudgetMonth = BudgetMonth(
            month: "2026-08", categoryBudgets: [makeBudget(id: "dining", name: "Dining Out", month: "2026-08")]
        )

        budgetStore.publishWidgetSnapshot()

        #expect(store.read()?.categories.map(\.id) == ["dining"])
    }

    @Test @MainActor func publishExcludesHiddenCategoryRows() throws {
        let budgetStore = BudgetStore.previewInstance()
        let store = try makeStore()
        budgetStore.widgetSnapshotStore = store
        budgetStore.widgetBudgetMonth = BudgetMonth(
            month: "2026-08",
            categoryBudgets: [makeBudget(id: "visible", name: "Visible", month: "2026-08")],
            toBudget: 0,
            hiddenCategoryBudgets: [makeBudget(id: "hidden", name: "Hidden", month: "2026-08")]
        )

        budgetStore.publishWidgetSnapshot()

        #expect(store.read()?.categories.map(\.id) == ["visible"])
    }

    @Test @MainActor func publishIsNoOpBeforeAnyBudgetLoads() throws {
        let budgetStore = BudgetStore.previewInstance()
        let store = try makeStore()
        budgetStore.widgetSnapshotStore = store
        budgetStore.widgetBudgetMonth = nil

        budgetStore.publishWidgetSnapshot()

        #expect(store.read() == nil)
    }

    @Test @MainActor func clearRemovesPublishedSnapshot() throws {
        let budgetStore = BudgetStore.previewInstance()
        let store = try makeStore()
        budgetStore.widgetSnapshotStore = store
        budgetStore.widgetBudgetMonth = BudgetMonth(
            month: "2026-08", categoryBudgets: [makeBudget(id: "dining", name: "Dining Out", month: "2026-08")]
        )
        budgetStore.publishWidgetSnapshot()

        budgetStore.clearWidgetSnapshot()

        #expect(store.read() == nil)
    }

    // MARK: - Building from category budgets

    @Test func makeSortsByGroupThenCategoryOrderAndFormats() {
        // Deliberately out of order: fetchBudgetMonth gives no order
        // guarantee, so make(from:) must sort the way the Budget tab does.
        let budgets = [
            CategoryBudget(
                month: "2026-08", categoryId: "grocery", categoryName: "Groceries",
                groupId: "g1", groupName: "Everyday", groupSortOrder: 0, categorySortOrder: 1,
                budgeted: 40000, spent: -42000, available: -2000, carryover: 0
            ),
            CategoryBudget(
                month: "2026-08", categoryId: "rent", categoryName: "Rent",
                groupId: "g0", groupName: "Bills", groupSortOrder: -1, categorySortOrder: 5,
                budgeted: 100_000, spent: -100_000, available: 0, carryover: 0
            ),
            CategoryBudget(
                month: "2026-08", categoryId: "dining", categoryName: "Dining Out",
                groupId: "g1", groupName: "Everyday", groupSortOrder: 0, categorySortOrder: 0,
                budgeted: 30000, spent: -17655, available: 12345, carryover: 0
            ),
        ]
        let generated = Date(timeIntervalSince1970: 1_750_000_000)

        let snapshot = WidgetSnapshot.make(
            from: budgets,
            month: "2026-08",
            balancesHidden: false,
            generatedAt: generated
        ) { cents in "<\(cents)>" }

        #expect(snapshot.month == "2026-08")
        #expect(snapshot.generatedAt == generated)
        #expect(snapshot.balancesHidden == false)
        #expect(snapshot.categories == [
            WidgetCategoryBalance(id: "rent", name: "Rent", available: 0, formattedAvailable: "<0>", budgeted: 100_000),
            WidgetCategoryBalance(id: "dining", name: "Dining Out", available: 12345, formattedAvailable: "<12345>", budgeted: 30000),
            WidgetCategoryBalance(id: "grocery", name: "Groceries", available: -2000, formattedAvailable: "<-2000>", budgeted: 40000),
        ])
    }

    // MARK: - Accounts & Net Worth

    @Test func makePopulatesAccountsAndNetWorth() {
        let accounts = [
            Account(id: "closed", name: "Old Checking", type: .checking, offBudget: false, closed: true, sortOrder: 0, balance: 10000),
            Account(id: "savings", name: "Savings", type: .savings, offBudget: false, closed: false, sortOrder: 2, balance: 500_000),
            Account(id: "checking", name: "Checking", type: .checking, offBudget: false, closed: false, sortOrder: 1, balance: 250_000),
        ]

        let snapshot = WidgetSnapshot.make(
            from: [],
            month: "2026-08",
            balancesHidden: false,
            generatedAt: Date(),
            format: { "$\($0)" },
            accounts: accounts
        )

        #expect(snapshot.accounts?.map(\.id) == ["checking", "savings"])
        #expect(snapshot.netWorth == 750_000)
        #expect(snapshot.formattedNetWorth == "$750000")
    }

    @Test func accountSelectionMatching() {
        var snapshot = sampleSnapshot()
        snapshot.accounts = [
            WidgetAccountBalance(id: "1", name: "Checking", balance: 100, formattedBalance: "$1", type: "checking", offBudget: false),
            WidgetAccountBalance(id: "2", name: "Savings", balance: 200, formattedBalance: "$2", type: "savings", offBudget: false),
            WidgetAccountBalance(id: "3", name: "Investment", balance: 300, formattedBalance: "$3", type: "investment", offBudget: true),
        ]

        // Custom selection
        let matched = snapshot.accounts(matching: ["3", "1"], limit: 2)
        #expect(matched.map(\.id) == ["3", "1"])

        // Empty selection falls back to on-budget accounts
        let fallback = snapshot.accounts(matching: [], limit: 4)
        #expect(fallback.map(\.id) == ["1", "2"])
    }

    // MARK: - To Be Budgeted & Spending

    @Test func makePopulatesToBeBudgetedAndSpending() {
        let month = BudgetMonth(
            month: "2026-08",
            categoryBudgets: [
                CategoryBudget(
                    month: "2026-08", categoryId: "c1", categoryName: "Groceries",
                    groupId: "g1", groupName: "Everyday", groupSortOrder: 0, categorySortOrder: 0,
                    budgeted: 200_000, spent: -150_000, available: 50000, carryover: 0
                ),
            ],
            incomeCategories: [
                IncomeCategory(
                    month: "2026-08", categoryId: "i1", categoryName: "Salary",
                    groupName: "Income", sortOrder: 0, budgeted: 0, received: 300_000
                ),
            ],
            toBudget: 45000
        )

        let snapshot = WidgetSnapshot.make(
            from: [],
            month: "2026-08",
            balancesHidden: false,
            generatedAt: Date(),
            format: { "$\($0)" },
            budgetMonth: month
        )

        #expect(snapshot.toBudget == 45000)
        #expect(snapshot.formattedToBudget == "$45000")
        #expect(snapshot.totalBudgeted == 200_000)
        #expect(snapshot.totalSpent == -150_000)
        #expect(snapshot.formattedTotalIncome == "$300000")
    }

    // MARK: - Upcoming Bills

    @Test func makePopulatesUpcomingBills() {
        let accounts = [
            Account(id: "a1", name: "Checking", type: .checking, offBudget: false, closed: false, sortOrder: 1, balance: 100),
            Account(id: "closed-acc", name: "Old", type: .checking, offBudget: false, closed: true, sortOrder: 2, balance: 0),
        ]

        let schedules = [
            ScheduleSummary(
                id: "s1", name: "Electric", ruleId: nil,
                nextDate: DayDate(year: 2026, month: 8, day: 25), nextDateRowId: nil, baseNextDateTs: nil,
                accountId: "a1", payeeId: nil,
                amount: .fixed(-12000), amountOp: .isExactly, dateOp: nil,
                dateCondition: nil, postsTransaction: true, completed: false,
                customUpcomingLength: nil, sortOrder: nil, isCustom: false,
                conditionsJSON: nil, actionsJSON: nil
            ),
            ScheduleSummary(
                id: "s2", name: "Completed Bill", ruleId: nil,
                nextDate: DayDate(year: 2026, month: 8, day: 20), nextDateRowId: nil, baseNextDateTs: nil,
                accountId: "a1", payeeId: nil,
                amount: .fixed(-5000), amountOp: .isExactly, dateOp: nil,
                dateCondition: nil, postsTransaction: true, completed: true,
                customUpcomingLength: nil, sortOrder: nil, isCustom: false,
                conditionsJSON: nil, actionsJSON: nil
            ),
            ScheduleSummary(
                id: "s3", name: "Internet", ruleId: nil,
                nextDate: DayDate(year: 2026, month: 8, day: 22), nextDateRowId: nil, baseNextDateTs: nil,
                accountId: "a1", payeeId: nil,
                amount: .fixed(-6000), amountOp: .isExactly, dateOp: nil,
                dateCondition: nil, postsTransaction: true, completed: false,
                customUpcomingLength: nil, sortOrder: nil, isCustom: false,
                conditionsJSON: nil, actionsJSON: nil
            ),
            ScheduleSummary(
                id: "s-paid", name: "Rent", ruleId: nil,
                nextDate: DayDate(year: 2026, month: 8, day: 21), nextDateRowId: nil, baseNextDateTs: nil,
                accountId: "a1", payeeId: nil,
                amount: .fixed(-100_000), amountOp: .isExactly, dateOp: nil,
                dateCondition: nil, postsTransaction: true, completed: false,
                customUpcomingLength: nil, sortOrder: nil, isCustom: false,
                conditionsJSON: nil, actionsJSON: nil
            ),
            ScheduleSummary(
                id: "s-closed", name: "Old Bill", ruleId: nil,
                nextDate: DayDate(year: 2026, month: 8, day: 23), nextDateRowId: nil, baseNextDateTs: nil,
                accountId: "closed-acc", payeeId: nil,
                amount: .fixed(-3000), amountOp: .isExactly, dateOp: nil,
                dateCondition: nil, postsTransaction: true, completed: false,
                customUpcomingLength: nil, sortOrder: nil, isCustom: false,
                conditionsJSON: nil, actionsJSON: nil
            ),
            ScheduleSummary(
                id: "s-empty-name", name: "", ruleId: nil,
                nextDate: DayDate(year: 2026, month: 8, day: 26), nextDateRowId: nil, baseNextDateTs: nil,
                accountId: "a1", payeeId: "p1",
                amount: .fixed(-4000), amountOp: .isExactly, dateOp: nil,
                dateCondition: nil, postsTransaction: true, completed: false,
                customUpcomingLength: nil, sortOrder: nil, isCustom: false,
                conditionsJSON: nil, actionsJSON: nil
            ),
        ]

        let payees = [Payee(id: "p1", name: "Netflix", transferAccountId: nil)]

        let snapshot = WidgetSnapshot.make(
            from: [],
            month: "2026-08",
            balancesHidden: false,
            generatedAt: Date(),
            format: { "$\($0)" },
            accounts: accounts,
            schedules: schedules,
            scheduleStatuses: ["s3": .due, "s-paid": .paid],
            payees: payees
        )

        // Paid (s-paid), completed (s2), and closed account (s-closed) are dropped
        #expect(snapshot.upcomingBills?.count == 3)
        #expect(snapshot.upcomingBills?[0].id == "s3") // earlier date (Aug 22 vs Aug 25)
        #expect(snapshot.upcomingBills?[0].status == .due)
        #expect(snapshot.upcomingBills?[1].id == "s1")
        #expect(snapshot.upcomingBills?[1].status == .upcoming)
        #expect(snapshot.upcomingBills?[2].id == "s-empty-name")
        #expect(snapshot.upcomingBills?[2].title == "Netflix") // empty name fell back to payee
    }

    @Test func upcomingBillsMarkMissedOverdueAndCapAtTwelve() {
        let snapshot = manyBillsSnapshot(count: 15, statuses: ["s1": .missed])

        // Extra Large Portrait shows up to 12, so the snapshot keeps 12.
        #expect(snapshot.upcomingBills?.map(\.id) == (1...12).map { "s\($0)" })
        #expect(snapshot.upcomingBills?.first?.status == .overdue)
    }

    // UpcomingBillsProvider's per-family limits; the provider lives in the
    // widget extension, so the tests mirror them here.
    private let billsSmallLimit = 1
    private let billsMediumLimit = 3
    private let billsLargeLimit = 6
    private let billsExtraLargePortraitLimit = 12

    private func billSchedules(count: Int) -> [ScheduleSummary] {
        (1...count).map { day in
            ScheduleSummary(
                id: "s\(day)", name: "Bill \(day)", ruleId: nil,
                nextDate: DayDate(year: 2026, month: 8, day: day), nextDateRowId: nil, baseNextDateTs: nil,
                accountId: "a1", payeeId: nil,
                amount: .fixed(-1000), amountOp: .isExactly, dateOp: nil,
                dateCondition: nil, postsTransaction: true, completed: false,
                customUpcomingLength: nil, sortOrder: nil, isCustom: false,
                conditionsJSON: nil, actionsJSON: nil
            )
        }
    }

    private let billAccount = Account(id: "a1", name: "Checking", type: .checking, offBudget: false, closed: false, sortOrder: 1, balance: 0)

    /// Schedules arrive reversed so every test also checks the due-date sort.
    private func manyBillsSnapshot(count: Int = 15, statuses: [String: ScheduleStatus] = [:]) -> WidgetSnapshot {
        WidgetSnapshot.make(
            from: [],
            month: "2026-08",
            balancesHidden: false,
            generatedAt: Date(),
            format: { "$\($0)" },
            accounts: [billAccount],
            schedules: billSchedules(count: count).reversed(),
            scheduleStatuses: statuses
        )
    }

    @Test func upcomingBillsShowNextBillsUpToFamilyLimit() {
        let snapshot = manyBillsSnapshot()

        #expect(snapshot.nextBills(limit: billsSmallLimit).map(\.id) == ["s1"])
        #expect(snapshot.nextBills(limit: billsMediumLimit).map(\.id) == ["s1", "s2", "s3"])
        #expect(snapshot.nextBills(limit: billsLargeLimit).map(\.id) == (1...6).map { "s\($0)" })
        #expect(snapshot.nextBills(limit: billsExtraLargePortraitLimit).map(\.id) == (1...12).map { "s\($0)" })
    }

    @Test func upcomingBillsFewerThanLimitShowsOnlyWhatExists() {
        let snapshot = manyBillsSnapshot(count: 2)

        for limit in [billsMediumLimit, billsLargeLimit, billsExtraLargePortraitLimit] {
            #expect(snapshot.nextBills(limit: limit).map(\.id) == ["s1", "s2"])
        }
    }

    @Test func upcomingBillsWithoutBillsDataShowNothing() {
        // Snapshots written before bills existed decode with nil.
        #expect(sampleSnapshot().nextBills(limit: billsExtraLargePortraitLimit).isEmpty)
    }

    @Test func upcomingBillsStaySortedByDueDateAcrossMonths() {
        let schedules = [
            (id: "sep", date: DayDate(year: 2026, month: 9, day: 1)),
            (id: "aug-late", date: DayDate(year: 2026, month: 8, day: 30)),
            (id: "aug-early", date: DayDate(year: 2026, month: 8, day: 2)),
        ].map { bill in
            ScheduleSummary(
                id: bill.id, name: bill.id, ruleId: nil,
                nextDate: bill.date, nextDateRowId: nil, baseNextDateTs: nil,
                accountId: "a1", payeeId: nil,
                amount: .fixed(-1000), amountOp: .isExactly, dateOp: nil,
                dateCondition: nil, postsTransaction: true, completed: false,
                customUpcomingLength: nil, sortOrder: nil, isCustom: false,
                conditionsJSON: nil, actionsJSON: nil
            )
        }

        let snapshot = WidgetSnapshot.make(
            from: [], month: "2026-08", balancesHidden: false, generatedAt: Date(), format: { "$\($0)" },
            accounts: [billAccount], schedules: schedules
        )

        #expect(snapshot.nextBills(limit: billsLargeLimit).map(\.id) == ["aug-early", "aug-late", "sep"])
    }

    @Test @MainActor func hiddenBalancesMaskEveryLargeAndExtraLargeBill() throws {
        let budgetStore = BudgetStore.previewInstance()
        let store = try makeStore()
        budgetStore.widgetSnapshotStore = store
        budgetStore.widgetBudgetMonth = BudgetMonth(month: "2026-08", categoryBudgets: [])
        budgetStore.accounts = [billAccount]
        budgetStore.schedules = billSchedules(count: 15)
        budgetStore.hideBalances = true
        defer { budgetStore.hideBalances = false }

        let snapshot = try #require(store.read())

        #expect(snapshot.balancesHidden)
        for limit in [billsLargeLimit, billsExtraLargePortraitLimit] {
            let shown = snapshot.nextBills(limit: limit)
            #expect(shown.count == limit)
            #expect(shown.allSatisfy { $0.formattedAmount == BudgetStore.hiddenBalanceText })
        }
    }
}
