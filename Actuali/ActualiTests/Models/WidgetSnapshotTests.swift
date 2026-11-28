import Foundation
import GRDB
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

    // CategoryBalanceProvider's per-family limits, from the table it reads.
    private let largeLimit = WidgetRowLimits.categoryBalance.large
    private let extraLargePortraitLimit = WidgetRowLimits.categoryBalance.extraLargePortrait

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

    // AccountBalanceProvider's per-family limits, from the table it reads.
    private let accountLargeLimit = WidgetRowLimits.accountBalance.large
    private let accountExtraLargePortraitLimit = WidgetRowLimits.accountBalance.extraLargePortrait

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

        let picked = manyAccountsSnapshot().accounts(matching: ids, limit: accountLargeLimit)

        // No selection falls back to the first eight on-budget accounts.
        #expect(picked.map(\.id) == (chosen == 0 ? (0..<8).map { "a\($0)" } : ids))
    }

    @Test func largeCapsAccountsAtEightWhenMoreChosen() {
        let ids = (0..<12).map { "a\($0)" }

        let picked = manyAccountsSnapshot().accounts(matching: ids, limit: accountLargeLimit)

        #expect(picked.map(\.id) == Array(ids.prefix(8)))
    }

    @Test(arguments: [0, 1, 6, 11, 12])
    func extraLargePortraitShowsChosenAccountsUpToTwelve(chosen: Int) {
        let ids = (0..<chosen).reversed().map { "a\($0)" }

        let picked = manyAccountsSnapshot().accounts(matching: ids, limit: accountExtraLargePortraitLimit)

        #expect(picked.map(\.id) == (chosen == 0 ? (0..<12).map { "a\($0)" } : ids))
    }

    @Test func extraLargePortraitCapsAccountsAtTwelveWhenMoreChosen() {
        let ids = (0..<15).map { "a\($0)" }

        let picked = manyAccountsSnapshot().accounts(matching: ids, limit: accountExtraLargePortraitLimit)

        #expect(picked.map(\.id) == Array(ids.prefix(12)))
    }

    @Test func fewerAccountsThanLimitShowsOnlyWhatExists() {
        let snapshot = manyAccountsSnapshot(count: 3)

        #expect(snapshot.accounts(matching: [], limit: accountLargeLimit).map(\.id) == ["a0", "a1", "a2"])
        #expect(snapshot.accounts(matching: [], limit: accountExtraLargePortraitLimit).map(\.id) == ["a0", "a1", "a2"])
        #expect(snapshot.accounts(matching: ["a2", "a0"], limit: accountExtraLargePortraitLimit).map(\.id) == ["a2", "a0"])
    }

    @Test func accountLimitAppliesAfterDroppingUnknownIds() {
        let known = (0..<15).map { "a\($0)" }
        let ids = known.flatMap { ["deleted-\($0)", $0] }
        let snapshot = manyAccountsSnapshot()

        #expect(snapshot.accounts(matching: ids, limit: accountLargeLimit).map(\.id) == Array(known.prefix(8)))
        #expect(snapshot.accounts(matching: ids, limit: accountExtraLargePortraitLimit).map(\.id) == Array(known.prefix(12)))
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
        for limit in [accountLargeLimit, accountExtraLargePortraitLimit] {
            let shown = snapshot.accounts(matching: [], limit: limit)
            #expect(shown.count == limit)
            #expect(shown.allSatisfy { $0.formattedBalance == BudgetStore.hiddenBalanceText })
        }
    }

    // NetWorthProvider has no account picker; it always takes the fallback
    // rows at these per-family limits.
    private let netWorthMediumLimit = WidgetRowLimits.netWorth.medium
    private let netWorthLargeLimit = WidgetRowLimits.netWorth.large
    private let netWorthExtraLargePortraitLimit = WidgetRowLimits.netWorth.extraLargePortrait

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
    private let toBudgetLargeLimit = WidgetRowLimits.toBeBudgeted.large
    private let toBudgetExtraLargePortraitLimit = WidgetRowLimits.toBeBudgeted.extraLargePortrait

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

    /// budgeted keeps its raw cents under the mask, so a filtered list would
    /// name exactly the categories with nothing assigned. Hidden balances
    /// list every category in budget order instead.
    @Test @MainActor func hiddenBalancesListEveryCategoryNotJustTheUnbudgetedOnes() throws {
        let budgetStore = BudgetStore.previewInstance()
        let store = try makeStore()
        budgetStore.widgetSnapshotStore = store
        budgetStore.widgetBudgetMonth = BudgetMonth(
            month: "2026-08",
            categoryBudgets: (0..<15).map {
                CategoryBudget(
                    month: "2026-08", categoryId: "c\($0)", categoryName: "Category \($0)",
                    groupId: "g1", groupName: "Everyday", groupSortOrder: 0, categorySortOrder: Double($0),
                    budgeted: $0.isMultiple(of: 2) ? 0 : 5000, spent: -500, available: 4500, carryover: 0
                )
            },
            toBudget: 45000
        )
        budgetStore.hideBalances = true
        defer { budgetStore.hideBalances = false }
        budgetStore.publishWidgetSnapshot()

        let hidden = try #require(store.read())
        for limit in [toBudgetLargeLimit, toBudgetExtraLargePortraitLimit] {
            #expect(hidden.unbudgetedCategories(limit: limit).map(\.id) == (0..<limit).map { "c\($0)" })
        }

        budgetStore.hideBalances = false
        budgetStore.publishWidgetSnapshot()
        let shown = try #require(store.read())
        #expect(shown.unbudgetedCategories(limit: toBudgetLargeLimit).map(\.id) == ["c0", "c2", "c4", "c6", "c8"])
    }

    // SpendingSummaryProvider's per-family category-row limits; Small and
    // Medium show totals only.
    private let spendingLargeLimit = WidgetRowLimits.spendingSummary.large
    private let spendingExtraLargePortraitLimit = WidgetRowLimits.spendingSummary.extraLargePortrait

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
    /// The shared row date must read exactly as the per-widget
    /// DateFormatter("MMM d") copies it replaced, in every shipped language.
    @Test(arguments: ["en", "en_GB", "fr", "es", "pt_BR", "de", "it", "nl"])
    func shortDateMatchesTheMonthDayTemplate(identifier: String) throws {
        let locale = Locale(identifier: identifier)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        for yyyymmdd in [20_260_105, 20_260_228, 20_260_930, 20_261_231] {
            let parts = DateComponents(year: yyyymmdd / 10000, month: yyyymmdd / 100 % 100, day: yyyymmdd % 100)
            let date = try #require(Calendar.current.date(from: parts))
            #expect(WidgetDateFormatting.shortDate(yyyymmdd, locale: locale) == formatter.string(from: date))
        }
    }

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
            WidgetCategoryBalance(
                id: "rent", name: "Rent", available: 0, formattedAvailable: "<0>", budgeted: 100_000,
                spent: -100_000, formattedSpent: "<100000>", formattedBudgeted: "<100000>"
            ),
            WidgetCategoryBalance(
                id: "dining", name: "Dining Out", available: 12345, formattedAvailable: "<12345>", budgeted: 30000,
                spent: -17655, formattedSpent: "<17655>", formattedBudgeted: "<30000>"
            ),
            WidgetCategoryBalance(
                id: "grocery", name: "Groceries", available: -2000, formattedAvailable: "<-2000>", budgeted: 40000,
                spent: -42000, formattedSpent: "<42000>", formattedBudgeted: "<40000>"
            ),
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

    // UpcomingBillsProvider's per-family limits, from the table it reads.
    private let billsSmallLimit = WidgetRowLimits.upcomingBills.small
    private let billsMediumLimit = WidgetRowLimits.upcomingBills.medium
    private let billsLargeLimit = WidgetRowLimits.upcomingBills.large
    private let billsExtraLargePortraitLimit = WidgetRowLimits.upcomingBills.extraLargePortrait

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

    // MARK: - Group 1: Transactions

    private func makeTransaction(
        id: String, date: Int, amount: Int, accountId: String = "a1",
        sortOrder: Double? = nil, transferAcct: String? = nil,
        categoryId: String = "c1", categoryName: String = "Groceries"
    ) -> Transaction {
        var transaction = Transaction(
            id: id, accountId: accountId, date: date, amount: amount,
            payeeId: nil, payeeName: "Payee \(id)", categoryId: categoryId, categoryName: categoryName,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: false, parentId: nil, tombstone: false, sortOrder: sortOrder, importedPayee: nil
        )
        transaction.transferAcct = transferAcct
        return transaction
    }

    private let onBudgetAccount = Account(id: "a1", name: "Checking", type: .checking, offBudget: false, closed: false, sortOrder: 1, balance: 0)
    private let offBudgetAccount = Account(id: "off", name: "Brokerage", type: .investment, offBudget: true, closed: false, sortOrder: 2, balance: 0)

    private func transactionSnapshot(
        _ transactions: [Transaction], balancesHidden: Bool = false, generatedAt: Date = Date()
    ) -> WidgetSnapshot {
        WidgetSnapshot.make(
            from: [], month: "2026-08", balancesHidden: balancesHidden, generatedAt: generatedAt,
            format: { balancesHidden ? "••••" : "$\($0)" },
            accounts: [onBudgetAccount, offBudgetAccount], transactions: transactions
        )
    }

    @Test func recentTransactionsAreNewestFirstAndCappedAtTwelve() throws {
        // Shuffled, with two same-day rows that only sort order separates —
        // BudgetStore appends new saves to the end of its list.
        let transactions = (1...15).map { makeTransaction(id: "t\($0)", date: 20_260_800 + $0, amount: -100) }
            + [makeTransaction(id: "late", date: 20_260_815, amount: -100, sortOrder: 2),
               makeTransaction(id: "early", date: 20_260_815, amount: -100, sortOrder: 1)]

        let snapshot = transactionSnapshot(transactions.shuffled())

        let recent = try #require(snapshot.recentTransactions)
        #expect(recent.map(\.id) == ["late", "early", "t15", "t14", "t13", "t12", "t11", "t10", "t9", "t8", "t7", "t6"])
        let first = try #require(recent.first)
        #expect(first.payeeName == "Payee late")
        #expect(first.categoryName == "Groceries")
        #expect(first.amount == -100)
        #expect(first.formattedAmount == "$-100")
        #expect(first.date == 20_260_815)
    }

    @Test func largestTransactionsAreThisMonthsSpendingOnlyAndCappedAtTwelve() throws {
        let spending = (1...15).map { makeTransaction(id: "s\($0)", date: 20_260_810, amount: -1000 * $0) }
        let excluded = [
            makeTransaction(id: "income", date: 20_260_810, amount: 999_999),
            makeTransaction(id: "last-month", date: 20_260_731, amount: -999_999),
            makeTransaction(id: "transfer", date: 20_260_810, amount: -999_999, transferAcct: "off"),
            makeTransaction(id: "off-budget", date: 20_260_810, amount: -999_999, accountId: "off"),
        ]

        let snapshot = transactionSnapshot((spending + excluded).shuffled())

        let largest = try #require(snapshot.largestTransactions)
        #expect(largest.map(\.id) == (4...15).reversed().map { "s\($0)" })
        #expect(largest.allSatisfy { $0.amount < 0 })
    }

    @Test func hiddenBalancesPickLargestTransactionsByDateNotAmount() throws {
        // The biggest purchases are the oldest, so an amount ranking would
        // surface s1...s3; under the mask only recency may choose the rows.
        let spending = (1...15).map { makeTransaction(id: "s\($0)", date: 20_260_800 + $0, amount: -100_000 + 1000 * $0) }

        let snapshot = transactionSnapshot(spending.shuffled(), balancesHidden: true)

        let largest = try #require(snapshot.largestTransactions)
        #expect(largest.map(\.id) == (4...15).reversed().map { "s\($0)" })
        #expect(largest.allSatisfy { $0.amount == 0 && $0.formattedAmount == "••••" })
    }

    @Test(arguments: [true, false])
    func hiddenCategoryNamesStayOffTransactionRows(balancesHidden: Bool) throws {
        var month = BudgetMonth(month: "2026-08", categoryBudgets: [])
        month.hiddenCategoryBudgets = [CategoryBudget(
            month: "2026-08", categoryId: "secret", categoryName: "Therapy",
            groupId: "g1", groupName: "Health", groupSortOrder: 0, categorySortOrder: 0,
            budgeted: 0, spent: -500, available: -500, carryover: 0, hidden: true
        )]
        let transactions = [
            makeTransaction(id: "hidden-cat", date: 20_260_810, amount: -500, categoryId: "secret", categoryName: "Therapy"),
            makeTransaction(id: "visible-cat", date: 20_260_809, amount: -300),
        ]

        // Hidden categories stay out of the widget whatever the balance mask
        // does, as the category rows leave them out (BudgetMonth's split).
        let snapshot = WidgetSnapshot.make(
            from: [], month: "2026-08", balancesHidden: balancesHidden, generatedAt: Date(),
            format: { balancesHidden ? "••••" : "$\($0)" },
            accounts: [onBudgetAccount], budgetMonth: month, transactions: transactions
        )

        let rows = try #require(snapshot.recentTransactions) + #require(snapshot.largestTransactions)
        #expect(rows.count == 4)
        for row in rows {
            #expect(row.categoryName == (row.id == "hidden-cat" ? nil : "Groceries"))
        }
    }

    /// A bill dated later this month hasn't happened yet: it neither tops
    /// Recent Transactions nor counts as one of this month's purchases.
    @Test(arguments: [false, true])
    func transactionListsLeaveOutTransactionsDatedAfterToday(balancesHidden: Bool) throws {
        let transactions = [
            makeTransaction(id: "today", date: 20_260_810, amount: -5000),
            makeTransaction(id: "earlier", date: 20_260_802, amount: -1000),
            makeTransaction(id: "rent", date: 20_260_825, amount: -145_000),
        ]
        let noonOnTheTenth = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 12)))

        let snapshot = transactionSnapshot(transactions.shuffled(), balancesHidden: balancesHidden, generatedAt: noonOnTheTenth)

        #expect(try #require(snapshot.recentTransactions).map(\.id) == ["today", "earlier"])
        #expect(try #require(snapshot.largestTransactions).map(\.id) == ["today", "earlier"])
    }

    @Test func transactionListsAreEmptyWithoutTransactions() {
        let snapshot = transactionSnapshot([])

        #expect(snapshot.recentTransactions == [])
        #expect(snapshot.largestTransactions == [])
    }

    @Test @MainActor func publishCarriesStoreTransactionsAndMasksThemWhenHidden() throws {
        let budgetStore = BudgetStore.previewInstance()
        let store = try makeStore()
        budgetStore.widgetSnapshotStore = store
        budgetStore.accounts = [onBudgetAccount]
        budgetStore.transactions = (1...15).map { makeTransaction(id: "t\($0)", date: 20_260_800 + $0, amount: $0.isMultiple(of: 2) ? 500 : -500) }
        budgetStore.widgetBudgetMonth = BudgetMonth(month: "2026-08", categoryBudgets: [])
        budgetStore.hideBalances = true
        defer { budgetStore.hideBalances = false }

        let snapshot = try #require(store.read())
        let recent = try #require(snapshot.recentTransactions)
        let largest = try #require(snapshot.largestTransactions)

        #expect(recent.count == 12)
        #expect(largest.count == 8)
        // Raw cents are zeroed too, so neither the amount nor an income sign
        // can leak through the mask.
        for row in recent + largest {
            #expect(row.formattedAmount == BudgetStore.hiddenBalanceText)
            #expect(row.amount == 0)
        }
    }

    // RecentTransactionsProvider's per-family limits, from the table it reads.
    private let recentSmallLimit = WidgetRowLimits.recentTransactions.small
    private let recentMediumLimit = WidgetRowLimits.recentTransactions.medium

    @Test func recentTransactionsShowNewestUpToFamilyLimit() {
        let snapshot = transactionSnapshot((1...15).map { makeTransaction(id: "t\($0)", date: 20_260_800 + $0, amount: -100) }.shuffled())

        #expect(snapshot.latestTransactions(limit: recentSmallLimit).map(\.id) == ["t15", "t14", "t13"])
        #expect(snapshot.latestTransactions(limit: recentMediumLimit).map(\.id) == ["t15", "t14", "t13", "t12"])
    }

    @Test func recentTransactionsFewerThanLimitShowsOnlyWhatExists() {
        let snapshot = transactionSnapshot([
            makeTransaction(id: "old", date: 20_260_801, amount: -100),
            makeTransaction(id: "new", date: 20_260_802, amount: -100),
        ])

        for limit in [recentSmallLimit, recentMediumLimit] {
            #expect(snapshot.latestTransactions(limit: limit).map(\.id) == ["new", "old"])
        }
        // Snapshots written before transactions existed decode with nil.
        #expect(sampleSnapshot().latestTransactions(limit: recentMediumLimit).isEmpty)
    }

    @Test @MainActor func hiddenBalancesMaskEverySmallAndMediumRecentTransaction() throws {
        let budgetStore = BudgetStore.previewInstance()
        let store = try makeStore()
        budgetStore.widgetSnapshotStore = store
        budgetStore.accounts = [onBudgetAccount]
        // Amounts grow with age, so only a date ordering yields t15 first.
        budgetStore.transactions = (1...15).map { makeTransaction(id: "t\($0)", date: 20_260_800 + $0, amount: -100_000 + 1000 * $0) }
        budgetStore.widgetBudgetMonth = BudgetMonth(month: "2026-08", categoryBudgets: [])
        budgetStore.hideBalances = true
        defer { budgetStore.hideBalances = false }

        let snapshot = try #require(store.read())

        #expect(snapshot.balancesHidden)
        for limit in [recentSmallLimit, recentMediumLimit] {
            let shown = snapshot.latestTransactions(limit: limit)
            #expect(shown.map(\.id) == (16 - limit...15).reversed().map { "t\($0)" })
            #expect(shown.allSatisfy { $0.formattedAmount == BudgetStore.hiddenBalanceText && $0.amount == 0 })
        }
    }

    // RecentTransactionsProvider's Large / Extra Large Portrait limits (#862).
    private let recentLargeLimit = WidgetRowLimits.recentTransactions.large
    private let recentExtraLargePortraitLimit = WidgetRowLimits.recentTransactions.extraLargePortrait

    @Test func recentTransactionsLargeAndExtraLargeShowNewestUpToFamilyLimit() {
        let snapshot = transactionSnapshot((1...15).map { makeTransaction(id: "t\($0)", date: 20_260_800 + $0, amount: -100) }.shuffled())

        #expect(snapshot.latestTransactions(limit: recentLargeLimit).map(\.id) == (8...15).reversed().map { "t\($0)" })
        // The snapshot itself caps at 12, so Extra Large Portrait is exactly full.
        #expect(snapshot.latestTransactions(limit: recentExtraLargePortraitLimit).map(\.id) == (4...15).reversed().map { "t\($0)" })
    }

    @Test func recentTransactionsLargeAndExtraLargeFewerThanLimitShowsOnlyWhatExists() {
        let snapshot = transactionSnapshot([
            makeTransaction(id: "old", date: 20_260_801, amount: -100),
            makeTransaction(id: "new", date: 20_260_802, amount: -100),
        ])

        for limit in [recentLargeLimit, recentExtraLargePortraitLimit] {
            #expect(snapshot.latestTransactions(limit: limit).map(\.id) == ["new", "old"])
            #expect(sampleSnapshot().latestTransactions(limit: limit).isEmpty)
        }
    }

    @Test func recentTransactionsLargeHeaderCarriesMonthTotal() {
        let snapshot = WidgetSnapshot.make(
            from: [], month: "2026-08", balancesHidden: false, generatedAt: Date(), format: { "$\($0)" },
            budgetMonth: spendingMonth("2026-08", spent: -42000)
        )

        #expect(snapshot.formattedTotalSpent == "$-42000")
        // The header reads positive, like Top Spending's and Monthly Spending under budget.
        #expect(snapshot.formattedTotalSpending == "$42000")
    }

    @Test @MainActor func hiddenBalancesMaskEveryLargeAndExtraLargeRecentTransactionAndMonthTotal() throws {
        let budgetStore = BudgetStore.previewInstance()
        let store = try makeStore()
        budgetStore.widgetSnapshotStore = store
        budgetStore.accounts = [onBudgetAccount]
        // Amounts grow with age, so only a date ordering yields t15 first.
        budgetStore.transactions = (1...15).map { makeTransaction(id: "t\($0)", date: 20_260_800 + $0, amount: -100_000 + 1000 * $0) }
        budgetStore.widgetBudgetMonth = spendingMonth("2026-08", spent: -42000)
        budgetStore.hideBalances = true
        defer { budgetStore.hideBalances = false }

        let snapshot = try #require(store.read())

        #expect(snapshot.balancesHidden)
        #expect(snapshot.formattedTotalSpent == BudgetStore.hiddenBalanceText)
        for limit in [recentLargeLimit, recentExtraLargePortraitLimit] {
            let shown = snapshot.latestTransactions(limit: limit)
            #expect(shown.map(\.id) == (16 - limit...15).reversed().map { "t\($0)" })
            #expect(shown.allSatisfy { $0.formattedAmount == BudgetStore.hiddenBalanceText && $0.amount == 0 })
        }
    }

    @Test func snapshotWrittenBeforePhaseTwoDecodesWithNewFieldsNil() throws {
        let legacy = """
        {"month":"2026-08","generatedAt":0,"balancesHidden":false,
         "categories":[{"id":"a","name":"Dining","available":100,"formattedAvailable":"$1.00"}]}
        """
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(legacy.utf8))

        #expect(snapshot.recentTransactions == nil)
        #expect(snapshot.largestTransactions == nil)
        #expect(snapshot.formattedTotalSpendingLastMonth == nil)
        #expect(snapshot.formattedSpendingPercentChange == nil)
        #expect(snapshot.rankedCategories == [])
        #expect(snapshot.categories.first?.spent == nil)
        #expect(snapshot.formattedAverageSpendPerDay == nil)
        #expect(snapshot.formattedSafeDailyRate == nil)
        #expect(snapshot.daysElapsed == nil)
        #expect(snapshot.daysRemaining == nil)
    }

    /// A snapshot left by a build that still wrote the raw comparison and
    /// rate cents decodes: the extra keys are ignored, and the app rewrites
    /// the snapshot on its next refresh.
    @Test func snapshotWithRetiredRawFieldsStillDecodes() throws {
        let older = """
        {"month":"2026-11","generatedAt":0,"balancesHidden":false,"categories":[],
         "totalSpentLastMonth":-40000,"spendingPercentChange":0.5,"averageSpendPerDay":2100,"safeDailyRate":2000,
         "formattedTotalSpendingLastMonth":"$400.00","formattedSpendingPercentChange":"+50%",
         "formattedAverageSpendPerDay":"$21.00","formattedSafeDailyRate":"$20.00"}
        """
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(older.utf8))

        #expect(snapshot.formattedTotalSpendingLastMonth == "$400.00")
        #expect(snapshot.formattedSpendingPercentChange == "+50%")
        #expect(snapshot.formattedAverageSpendPerDay == "$21.00")
        #expect(snapshot.formattedSafeDailyRate == "$20.00")
    }

    // MARK: Largest Transactions widget

    // LargestTransactionsProvider's per-family limits, from the table it reads.
    private let largestSmallLimit = WidgetRowLimits.largestTransactions.small
    private let largestMediumLimit = WidgetRowLimits.largestTransactions.medium

    @Test func largestTransactionsShowBiggestSpendingUpToFamilyLimit() {
        let spending = (1...5).map { makeTransaction(id: "s\($0)", date: 20_260_800 + $0, amount: -1000 * $0) }
        let income = makeTransaction(id: "income", date: 20_260_810, amount: 999_999)

        let snapshot = transactionSnapshot((spending + [income]).shuffled())

        #expect(snapshot.largestTransactions(limit: largestSmallLimit).map(\.id) == ["s5"])
        #expect(snapshot.largestTransactions(limit: largestMediumLimit).map(\.id) == ["s5", "s4", "s3"])
        #expect(snapshot.largestTransactions(limit: largestMediumLimit).map(\.formattedAmount) == ["$-5000", "$-4000", "$-3000"])
    }

    @Test func largestTransactionsFewerThanLimitShowsOnlyWhatExists() {
        let snapshot = transactionSnapshot([
            makeTransaction(id: "only", date: 20_260_801, amount: -100),
            makeTransaction(id: "income", date: 20_260_802, amount: 5000),
        ])
        let incomeOnly = transactionSnapshot([makeTransaction(id: "income", date: 20_260_802, amount: 5000)])

        for limit in [largestSmallLimit, largestMediumLimit] {
            #expect(snapshot.largestTransactions(limit: limit).map(\.id) == ["only"])
            // Income alone leaves the widget to its empty state.
            #expect(incomeOnly.largestTransactions(limit: limit).isEmpty)
            // Snapshots written before transactions existed decode with nil.
            #expect(sampleSnapshot().largestTransactions(limit: limit).isEmpty)
        }
    }

    @Test @MainActor func hiddenBalancesShowSmallAndMediumLargestTransactionsByDateMasked() throws {
        let budgetStore = BudgetStore.previewInstance()
        let store = try makeStore()
        budgetStore.widgetSnapshotStore = store
        budgetStore.accounts = [onBudgetAccount]
        // Amounts shrink with recency, so an amount ranking would put t1
        // first; under the mask only the newest may lead.
        budgetStore.transactions = (1...15).map { makeTransaction(id: "t\($0)", date: 20_260_800 + $0, amount: -100_000 + 1000 * $0) }
        budgetStore.widgetBudgetMonth = BudgetMonth(month: "2026-08", categoryBudgets: [])
        budgetStore.hideBalances = true
        defer { budgetStore.hideBalances = false }

        let snapshot = try #require(store.read())

        for limit in [largestSmallLimit, largestMediumLimit] {
            let shown = snapshot.largestTransactions(limit: limit)
            #expect(shown.map(\.id) == (16 - limit...15).reversed().map { "t\($0)" })
            #expect(shown.allSatisfy { $0.formattedAmount == BudgetStore.hiddenBalanceText && $0.amount == 0 })
        }
    }

    // LargestTransactionsProvider's Large / Extra Large Portrait limits (#862).
    private let largestLargeLimit = WidgetRowLimits.largestTransactions.large
    private let largestExtraLargePortraitLimit = WidgetRowLimits.largestTransactions.extraLargePortrait

    @Test func largestTransactionsLargeAndExtraLargeShowBiggestSpendingUpToFamilyLimit() {
        let spending = (1...10).map { makeTransaction(id: "s\($0)", date: 20_260_800 + $0, amount: -1000 * $0) }
        let income = makeTransaction(id: "income", date: 20_260_810, amount: 999_999)

        let snapshot = transactionSnapshot((spending + [income]).shuffled())

        #expect(snapshot.largestTransactions(limit: largestLargeLimit).map(\.id) == (6...10).reversed().map { "s\($0)" })
        #expect(snapshot.largestTransactions(limit: largestExtraLargePortraitLimit).map(\.id) == (3...10).reversed().map { "s\($0)" })
        // Amounts arrive pre-formatted, so the widget never formats them itself.
        #expect(snapshot.largestTransactions(limit: largestLargeLimit).first?.formattedAmount == "$-10000")
    }

    @Test func largestTransactionsLargeAndExtraLargeFewerThanLimitShowsOnlyWhatExists() {
        let snapshot = transactionSnapshot([
            makeTransaction(id: "small", date: 20_260_801, amount: -100),
            makeTransaction(id: "big", date: 20_260_802, amount: -900),
            makeTransaction(id: "income", date: 20_260_803, amount: 5000),
        ])

        for limit in [largestLargeLimit, largestExtraLargePortraitLimit] {
            #expect(snapshot.largestTransactions(limit: limit).map(\.id) == ["big", "small"])
            // Snapshots written before transactions existed decode with nil.
            #expect(sampleSnapshot().largestTransactions(limit: limit).isEmpty)
        }
    }

    @Test func largestTransactionsLargeHeaderCarriesTotalSpent() {
        let snapshot = WidgetSnapshot.make(
            from: [], month: "2026-08", balancesHidden: false, generatedAt: Date(), format: { "$\($0)" },
            accounts: [onBudgetAccount], budgetMonth: spendingMonth("2026-08", spent: -42000),
            transactions: [makeTransaction(id: "s1", date: 20_260_810, amount: -500)]
        )

        #expect(snapshot.formattedTotalSpent == "$-42000")
        // The total row reads positive, like Top Spending's header.
        #expect(snapshot.formattedTotalSpending == "$42000")
        #expect(snapshot.largestTransactions(limit: largestLargeLimit).map(\.id) == ["s1"])
    }

    @Test @MainActor func hiddenBalancesShowLargeAndExtraLargeLargestTransactionsByDateMaskedWithTotal() throws {
        let budgetStore = BudgetStore.previewInstance()
        let store = try makeStore()
        budgetStore.widgetSnapshotStore = store
        budgetStore.accounts = [onBudgetAccount]
        // Amounts shrink with recency, so an amount ranking would put t1
        // first; under the mask only the newest may lead.
        budgetStore.transactions = (1...15).map { makeTransaction(id: "t\($0)", date: 20_260_800 + $0, amount: -100_000 + 1000 * $0) }
        budgetStore.widgetBudgetMonth = spendingMonth("2026-08", spent: -42000)
        budgetStore.hideBalances = true
        defer { budgetStore.hideBalances = false }

        let snapshot = try #require(store.read())

        #expect(snapshot.balancesHidden)
        #expect(snapshot.formattedTotalSpent == BudgetStore.hiddenBalanceText)
        for limit in [largestLargeLimit, largestExtraLargePortraitLimit] {
            let shown = snapshot.largestTransactions(limit: limit)
            #expect(shown.map(\.id) == (16 - limit...15).reversed().map { "t\($0)" })
            #expect(shown.allSatisfy { $0.formattedAmount == BudgetStore.hiddenBalanceText && $0.amount == 0 })
        }
    }

    // MARK: - Group 2: Month aggregates

    private func spendingMonth(_ month: String, spent: Int, budgeted: Int = 100_000) -> BudgetMonth {
        BudgetMonth(month: month, categoryBudgets: [
            CategoryBudget(
                month: month, categoryId: "c1", categoryName: "Groceries",
                groupId: "g1", groupName: "Everyday", groupSortOrder: 0, categorySortOrder: 0,
                budgeted: budgeted, spent: spent, available: budgeted + spent, carryover: 0
            ),
        ])
    }

    private func aggregateSnapshot(this: BudgetMonth, last: Int?, balancesHidden: Bool = false) -> WidgetSnapshot {
        WidgetSnapshot.make(
            from: this.categoryBudgets, month: this.month, balancesHidden: balancesHidden, generatedAt: Date(),
            format: { balancesHidden ? "••••" : "$\($0)" },
            budgetMonth: this, monthToDateSpending: last.map { toDate(this.categoryBudgets, last: ["c1": $0]) }
        )
    }

    /// No transaction in these fixtures is dated after today, so this month
    /// to date is each category's full Spent figure.
    private func toDate(_ budgets: [CategoryBudget], last: [String: Int]) -> MonthToDateSpending {
        MonthToDateSpending(
            thisMonth: Dictionary(uniqueKeysWithValues: budgets.map { ($0.categoryId, $0.spent) }), lastMonth: last
        )
    }

    /// The builder's percent format, so a ratio can be checked as the widget shows it.
    private func percent(_ ratio: Double) -> String {
        ratio.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false)))
    }

    @Test func lastMonthDifferenceAndPercentChangeCompareSpending() {
        let snapshot = aggregateSnapshot(
            this: spendingMonth("2026-08", spent: -60000),
            last: -40000
        )

        #expect(snapshot.totalSpent == -60000)
        #expect(snapshot.formattedTotalSpendingLastMonth == "$40000")
        // Positive means spending more this month than last.
        #expect(snapshot.spendingDifference == 20000)
        #expect(snapshot.formattedSpendingDifference == "$20000")
        #expect(snapshot.formattedSpendingPercentChange == percent(0.5))
    }

    /// A transaction dated later this month (a posted schedule, say) is in
    /// the full-month Spent figure but has no match on last month's side, so
    /// the comparison stops at today while the Monthly Spending header keeps
    /// the whole month.
    @Test func comparisonUsesSpendingToDateNotTheFullMonth() {
        let month = spendingMonth("2026-11", spent: -180_000)
        let snapshot = WidgetSnapshot.make(
            from: month.categoryBudgets, month: month.month, balancesHidden: false, generatedAt: Date(),
            format: { "$\($0)" }, budgetMonth: month,
            monthToDateSpending: MonthToDateSpending(thisMonth: ["c1": -30000], lastMonth: ["c1": -40000])
        )

        #expect(snapshot.formattedTotalSpending == "$180000")
        #expect(snapshot.formattedTotalSpendingToDate == "$30000")
        #expect(snapshot.spendingDifference == -10000)
        #expect(snapshot.formattedSpendingPercentChange == percent(-0.25))
        #expect(snapshot.spendingTrend == .less)
        #expect(snapshot.categories.first?.spendingDifference == -10000)
    }

    @Test func spendingLessThanLastMonthIsNegativeChange() {
        let snapshot = aggregateSnapshot(
            this: spendingMonth("2026-08", spent: -30000),
            last: -40000
        )

        #expect(snapshot.spendingDifference == -10000)
        #expect(snapshot.formattedSpendingPercentChange == percent(-0.25))
    }

    @Test func noLastMonthDataLeavesComparisonNil() {
        let snapshot = aggregateSnapshot(this: spendingMonth("2026-08", spent: -30000), last: nil)

        #expect(snapshot.formattedTotalSpendingLastMonth == nil)
        #expect(snapshot.spendingDifference == nil)
        #expect(snapshot.formattedSpendingDifference == nil)
        #expect(snapshot.formattedSpendingPercentChange == nil)
    }

    @Test func noSpendingLastMonthHasDifferenceButNoPercent() {
        let snapshot = aggregateSnapshot(
            this: spendingMonth("2026-08", spent: -30000),
            last: 0
        )

        #expect(snapshot.formattedTotalSpendingLastMonth == "$0")
        #expect(snapshot.spendingDifference == 30000)
        #expect(snapshot.formattedSpendingPercentChange == nil)
    }

    @Test func hiddenBalancesNeutralizeMonthAggregates() {
        let snapshot = aggregateSnapshot(
            this: spendingMonth("2026-08", spent: -60000),
            last: -40000,
            balancesHidden: true
        )

        #expect(snapshot.spendingDifference == 0)
        #expect(snapshot.formattedTotalSpendingToDate == "••••")
        #expect(snapshot.formattedTotalSpendingLastMonth == "••••")
        #expect(snapshot.formattedSpendingDifference == "••••")
        #expect(snapshot.formattedSpendingPercentChange == "••••")
    }

    @Test func spendingTrendFollowsTheDifferenceSign() {
        let more = aggregateSnapshot(this: spendingMonth("2026-08", spent: -60000), last: -40000)
        let less = aggregateSnapshot(this: spendingMonth("2026-08", spent: -30000), last: -40000)
        let same = aggregateSnapshot(this: spendingMonth("2026-08", spent: -40000), last: -40000)

        #expect(more.spendingTrend == .more)
        #expect(less.spendingTrend == .less)
        #expect(same.spendingTrend == .same)
    }

    @Test func spendingTrendWithNoSpendingLastMonthIsMore() {
        let snapshot = aggregateSnapshot(this: spendingMonth("2026-08", spent: -30000), last: 0)

        #expect(snapshot.spendingTrend == .more)
    }

    @Test func spendingTrendIsNilWithoutLastMonthData() {
        let snapshot = aggregateSnapshot(this: spendingMonth("2026-08", spent: -30000), last: nil)

        #expect(snapshot.spendingTrend == nil)
    }

    /// The zeroed difference would otherwise read as "same", and an arrow or
    /// red would leak the direction through the mask.
    @Test func spendingTrendIsNilWhenBalancesHidden() {
        let snapshot = aggregateSnapshot(
            this: spendingMonth("2026-08", spent: -60000),
            last: -40000,
            balancesHidden: true
        )

        #expect(snapshot.spendingTrend == nil)
        #expect(snapshot.formattedSpendingDifference == "••••")
    }

    @Test func legacySnapshotHasNoSpendingTrend() throws {
        let legacy = """
        {"month":"2026-08","generatedAt":0,"balancesHidden":false,"categories":[]}
        """
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: Data(legacy.utf8))

        #expect(snapshot.spendingTrend == nil)
    }

    @Test @MainActor func publishFillsLastMonthComparisonFromTheStore() throws {
        let budgetStore = BudgetStore.previewInstance()
        let store = try makeStore()
        budgetStore.widgetSnapshotStore = store
        budgetStore.widgetMonthToDateSpending = MonthToDateSpending(thisMonth: ["c1": -60000], lastMonth: ["c1": -40000])
        budgetStore.widgetBudgetMonth = spendingMonth("2026-08", spent: -60000)

        budgetStore.publishWidgetSnapshot()

        let snapshot = try #require(store.read())

        #expect(snapshot.formattedTotalSpendingToDate == budgetStore.displayBalance(60000))
        #expect(snapshot.formattedTotalSpendingLastMonth == budgetStore.displayBalance(40000))
        #expect(snapshot.spendingDifference == 20000)
        #expect(snapshot.formattedSpendingDifference == budgetStore.displayBalance(20000))
        #expect(snapshot.formattedSpendingPercentChange == percent(0.5))
    }

    @Test @MainActor func publishLeavesComparisonNilWithoutLastMonthData() throws {
        let budgetStore = BudgetStore.previewInstance()
        let store = try makeStore()
        budgetStore.widgetSnapshotStore = store
        budgetStore.widgetMonthToDateSpending = MonthToDateSpending(thisMonth: ["c1": -60000], lastMonth: [:])
        budgetStore.widgetBudgetMonth = spendingMonth("2026-08", spent: -60000)

        budgetStore.publishWidgetSnapshot()

        let snapshot = try #require(store.read())

        #expect(snapshot.totalSpent == -60000)
        #expect(snapshot.formattedTotalSpendingLastMonth == nil)
        #expect(snapshot.spendingDifference == nil)
        #expect(snapshot.formattedSpendingDifference == nil)
        #expect(snapshot.formattedSpendingPercentChange == nil)
    }

    @Test @MainActor func publishMasksEveryComparisonAmountAndRateWhenHidden() throws {
        let budgetStore = BudgetStore.previewInstance()
        let store = try makeStore()
        budgetStore.widgetSnapshotStore = store
        budgetStore.widgetMonthToDateSpending = MonthToDateSpending(thisMonth: ["c1": -60000], lastMonth: ["c1": -40000])
        budgetStore.hideBalances = true
        defer { budgetStore.hideBalances = false }
        // The current month, so the daily rates are filled too.
        let month = Calendar.current.dateComponents([.year, .month], from: Date())
        budgetStore.widgetBudgetMonth = spendingMonth(
            String(format: "%04d-%02d", month.year ?? 0, month.month ?? 0), spent: -60000
        )

        budgetStore.publishWidgetSnapshot()

        let snapshot = try #require(store.read())

        let mask = BudgetStore.hiddenBalanceText
        #expect(snapshot.spendingDifference == 0)
        #expect(snapshot.formattedTotalSpendingLastMonth == mask)
        #expect(snapshot.formattedSpendingDifference == mask)
        #expect(snapshot.formattedSpendingPercentChange == mask)
        #expect(snapshot.formattedAverageSpendPerDay == mask)
        #expect(snapshot.formattedSafeDailyRate == mask)
    }

    // MARK: - Group 3: Ranked categories

    private func rankedBudget(_ id: String, order: Double, budgeted: Int, spent: Int, carryover: Int = 0) -> CategoryBudget {
        CategoryBudget(
            month: "2026-08", categoryId: id, categoryName: id.capitalized,
            groupId: "g1", groupName: "Everyday", groupSortOrder: 0, categorySortOrder: order,
            budgeted: budgeted, spent: spent, available: budgeted + spent + carryover, carryover: carryover
        )
    }

    @Test func rankedCategoriesSortBySpendingDescendingWithOverspentFlag() throws {
        let budgets = [
            rankedBudget("rent", order: 0, budgeted: 150_000, spent: -150_000),
            rankedBudget("dining", order: 1, budgeted: 20000, spent: -35000),
            rankedBudget("refunds", order: 2, budgeted: 0, spent: 5000),
            rankedBudget("fun", order: 3, budgeted: 10000, spent: 0),
            rankedBudget("gas", order: 4, budgeted: 10000, spent: 0),
        ]

        let snapshot = WidgetSnapshot.make(
            from: budgets.shuffled(), month: "2026-08", balancesHidden: false, generatedAt: Date(), format: { "$\($0)" }
        )

        let ranked = snapshot.rankedCategories
        // Net inflows rank last; ties keep budget order.
        #expect(ranked.map(\.id) == ["rent", "dining", "fun", "gas", "refunds"])
        let dining = try #require(ranked.first { $0.id == "dining" })
        #expect(dining.name == "Dining")
        #expect(dining.spent == -35000)
        #expect(dining.budgeted == 20000)
        #expect(dining.formattedSpent == "$35000")
        #expect(dining.formattedBudgeted == "$20000")
        #expect(dining.formattedAvailable == "$-15000")
        #expect(dining.isOverspent)
        #expect(ranked.filter(\.isOverspent).map(\.id) == ["dining"])
        // Ranking reads the existing list rather than storing a second copy.
        #expect(Set(ranked.map(\.id)) == Set(snapshot.categories.map(\.id)))
    }

    @Test func rankedCategoriesCapAtTwelve() {
        let budgets = (0..<15).map { rankedBudget("c\($0)", order: Double($0), budgeted: 0, spent: -100 * $0) }

        let snapshot = WidgetSnapshot.make(
            from: budgets, month: "2026-08", balancesHidden: false, generatedAt: Date(), format: { "$\($0)" }
        )

        #expect(snapshot.rankedCategories.map(\.id) == (3..<15).reversed().map { "c\($0)" })
    }

    @Test func hiddenBalancesMaskRankedCategoriesAndKeepBudgetOrder() {
        let budgets = [
            rankedBudget("small", order: 0, budgeted: 100, spent: -100),
            rankedBudget("big", order: 1, budgeted: 100, spent: -90000),
        ]

        let snapshot = WidgetSnapshot.make(
            from: budgets, month: "2026-08", balancesHidden: true, generatedAt: Date(), format: { _ in "••••" }
        )

        // Spent is zeroed under the mask, so the order can't rank by it either.
        #expect(snapshot.rankedCategories.map(\.id) == ["small", "big"])
        for category in snapshot.rankedCategories {
            #expect(category.spent == 0)
            #expect(category.formattedSpent == "••••")
            #expect(category.formattedBudgeted == "••••")
            #expect(category.formattedAvailable == "••••")
        }
    }

    // TopSpendingProvider's per-family limits, from the table it reads.
    private let topSpendingSmallLimit = WidgetRowLimits.topSpending.small
    private let topSpendingMediumLimit = WidgetRowLimits.topSpending.medium

    @Test func topSpendingShowsLargestSpendersUpToFamilyLimit() {
        let budgets = (1...5).map { rankedBudget("c\($0)", order: Double($0), budgeted: 0, spent: -100 * $0) }

        let snapshot = WidgetSnapshot.make(
            from: budgets.shuffled(), month: "2026-08", balancesHidden: false, generatedAt: Date(), format: { "$\($0)" }
        )

        #expect(snapshot.topSpendingCategories(limit: topSpendingSmallLimit).map(\.id) == ["c5"])
        #expect(snapshot.topSpendingCategories(limit: topSpendingMediumLimit).map(\.id) == ["c5", "c4", "c3"])
    }

    @Test func topSpendingSkipsCategoriesWithoutSpending() {
        let budgets = [
            rankedBudget("refunds", order: 0, budgeted: 0, spent: 5000),
            rankedBudget("idle", order: 1, budgeted: 10000, spent: 0),
            rankedBudget("dining", order: 2, budgeted: 20000, spent: -35000),
        ]
        let quiet = [rankedBudget("idle", order: 0, budgeted: 10000, spent: 0)]

        let snapshot = WidgetSnapshot.make(
            from: budgets, month: "2026-08", balancesHidden: false, generatedAt: Date(), format: { "$\($0)" }
        )
        let quietSnapshot = WidgetSnapshot.make(
            from: quiet, month: "2026-08", balancesHidden: false, generatedAt: Date(), format: { "$\($0)" }
        )

        for limit in [topSpendingSmallLimit, topSpendingMediumLimit] {
            // Fewer spenders than the limit shows only what exists.
            #expect(snapshot.topSpendingCategories(limit: limit).map(\.id) == ["dining"])
            // Nothing spent yet leaves the widget to its empty state.
            #expect(quietSnapshot.topSpendingCategories(limit: limit).isEmpty)
            // Snapshots written before spent existed decode with nil.
            #expect(sampleSnapshot().topSpendingCategories(limit: limit).isEmpty)
        }
    }

    @Test func hiddenBalancesKeepTopSpendingInBudgetOrderMasked() {
        let budgets = [
            rankedBudget("small", order: 0, budgeted: 100, spent: -100),
            rankedBudget("idle", order: 1, budgeted: 100, spent: 0),
            rankedBudget("big", order: 2, budgeted: 100, spent: -90000),
            rankedBudget("refunds", order: 3, budgeted: 0, spent: 5000),
        ]

        let snapshot = WidgetSnapshot.make(
            from: budgets, month: "2026-08", balancesHidden: true, generatedAt: Date(), format: { _ in "••••" }
        )

        // Spent is zeroed under the mask, so dropping non-spenders would
        // blank the widget; budget order keeps which ones spent unknown.
        #expect(snapshot.topSpendingCategories(limit: topSpendingSmallLimit).map(\.id) == ["small"])
        #expect(snapshot.topSpendingCategories(limit: topSpendingMediumLimit).map(\.id) == ["small", "idle", "big"])
        for category in snapshot.topSpendingCategories(limit: topSpendingMediumLimit) {
            #expect(category.formattedSpent == "••••")
            #expect(category.formattedBudgeted == "••••")
            #expect(category.formattedAvailable == "••••")
        }
    }

    // TopSpendingProvider's Large / Extra Large Portrait limits (#862).
    private let topSpendingLargeLimit = WidgetRowLimits.topSpending.large
    private let topSpendingExtraLargePortraitLimit = WidgetRowLimits.topSpending.extraLargePortrait

    @Test func topSpendingLargeAndExtraLargeShowLargestSpendersUpToFamilyLimit() {
        let budgets = (1...10).map { rankedBudget("c\($0)", order: Double($0), budgeted: 0, spent: -100 * $0) }

        let snapshot = WidgetSnapshot.make(
            from: budgets.shuffled(), month: "2026-08", balancesHidden: false, generatedAt: Date(), format: { "$\($0)" }
        )

        #expect(snapshot.topSpendingCategories(limit: topSpendingLargeLimit).map(\.id) == (6...10).reversed().map { "c\($0)" })
        #expect(snapshot.topSpendingCategories(limit: topSpendingExtraLargePortraitLimit).map(\.id) == (3...10).reversed().map { "c\($0)" })
    }

    @Test func topSpendingLargeAndExtraLargeFewerSpendersThanLimitShowsOnlyWhatExists() {
        let budgets = [
            rankedBudget("refunds", order: 0, budgeted: 0, spent: 5000),
            rankedBudget("idle", order: 1, budgeted: 10000, spent: 0),
            rankedBudget("gas", order: 2, budgeted: 10000, spent: -4000),
            rankedBudget("dining", order: 3, budgeted: 20000, spent: -35000),
        ]

        let snapshot = WidgetSnapshot.make(
            from: budgets, month: "2026-08", balancesHidden: false, generatedAt: Date(), format: { "$\($0)" }
        )

        for limit in [topSpendingLargeLimit, topSpendingExtraLargePortraitLimit] {
            #expect(snapshot.topSpendingCategories(limit: limit).map(\.id) == ["dining", "gas"])
            #expect(sampleSnapshot().topSpendingCategories(limit: limit).isEmpty)
        }
    }

    @Test func topSpendingLargeHeaderCarriesTotalSpent() {
        let snapshot = WidgetSnapshot.make(
            from: [], month: "2026-08", balancesHidden: false, generatedAt: Date(), format: { "$\($0)" },
            budgetMonth: spendingMonth("2026-08", spent: -42000)
        )

        #expect(snapshot.formattedTotalSpent == "$-42000")
        // The header reads positive, like the Spent column beneath it.
        #expect(snapshot.formattedTotalSpending == "$42000")
    }

    @Test @MainActor func hiddenBalancesKeepLargeAndExtraLargeTopSpendingInBudgetOrderMaskedWithTotal() throws {
        let budgetStore = BudgetStore.previewInstance()
        let store = try makeStore()
        budgetStore.widgetSnapshotStore = store
        // Spending grows against budget order, so only budget order yields c1 first.
        let budgets = (1...10).map { rankedBudget("c\($0)", order: Double($0), budgeted: 100, spent: -100 * $0) }
        budgetStore.widgetBudgetMonth = BudgetMonth(month: "2026-08", categoryBudgets: budgets)
        budgetStore.hideBalances = true
        defer { budgetStore.hideBalances = false }

        let snapshot = try #require(store.read())

        #expect(snapshot.balancesHidden)
        #expect(snapshot.formattedTotalSpent == BudgetStore.hiddenBalanceText)
        for limit in [topSpendingLargeLimit, topSpendingExtraLargePortraitLimit] {
            let shown = snapshot.topSpendingCategories(limit: limit)
            #expect(shown.map(\.id) == (1...limit).map { "c\($0)" })
            for category in shown {
                #expect(category.spent == 0)
                #expect(category.formattedSpent == BudgetStore.hiddenBalanceText)
                #expect(category.formattedBudgeted == BudgetStore.hiddenBalanceText)
                #expect(category.formattedAvailable == BudgetStore.hiddenBalanceText)
            }
        }
    }

    /// OverspentAlertsWidget's Medium row cap, from the table it reads.
    private let overspentMediumLimit = WidgetRowLimits.overspentAlerts.medium

    @Test func overspentAlertsKeepOnlyOverspentCategoriesMostSpentFirst() {
        let budgets = [
            rankedBudget("rent", order: 0, budgeted: 150_000, spent: -150_000),
            rankedBudget("dining", order: 1, budgeted: 20000, spent: -35000),
            rankedBudget("refunds", order: 2, budgeted: 0, spent: 5000),
            rankedBudget("gas", order: 3, budgeted: 10000, spent: -12000),
            rankedBudget("fun", order: 4, budgeted: 0, spent: 0, carryover: -500),
            rankedBudget("gifts", order: 5, budgeted: 1000, spent: -2000),
            rankedBudget("pets", order: 6, budgeted: 1000, spent: -3000),
            rankedBudget("books", order: 7, budgeted: 1000, spent: -900),
        ]

        let snapshot = WidgetSnapshot.make(
            from: budgets.shuffled(), month: "2026-08", balancesHidden: false, generatedAt: Date(), format: { "$\($0)" }
        )

        // Exactly-spent, underspent and inflow categories drop out; negative
        // carryover counts as overspent even with no spending this month.
        let overspent = snapshot.overspentCategories
        #expect(overspent.map(\.id) == ["dining", "gas", "pets", "gifts", "fun"])
        // Outside #expect: the macro splits `allSatisfy(\.isOverspent)` into a
        // forwarded call that loses `rethrows` and fails to compile.
        let allOverspent = overspent.allSatisfy(\.isOverspent)
        #expect(allOverspent)
        // Small shows the full count; Medium the first four.
        #expect(overspent.count == 5)
        #expect(overspent.prefix(overspentMediumLimit).map(\.id) == ["dining", "gas", "pets", "gifts"])
    }

    @Test func overspentAlertsEmptyWhenNothingOverspent() {
        let budgets = [
            rankedBudget("rent", order: 0, budgeted: 150_000, spent: -150_000),
            rankedBudget("refunds", order: 1, budgeted: 0, spent: 5000),
        ]

        let snapshot = WidgetSnapshot.make(
            from: budgets, month: "2026-08", balancesHidden: false, generatedAt: Date(), format: { "$\($0)" }
        )

        #expect(snapshot.overspentCategories.isEmpty)
        // Snapshots written before spent existed rank nothing.
        #expect(sampleSnapshot().overspentCategories.isEmpty)
    }

    /// Twelve big spenders, none overspent, crowd the top 12. Gifts ($40
    /// spent, nothing budgeted) and Repairs (overspent by carryover alone)
    /// sit below them, and must still show and count.
    private var crowdedBudgets: [CategoryBudget] {
        (0..<12).map { rankedBudget("big\($0)", order: Double($0), budgeted: 100_000, spent: -50000 - $0) }
            + [
                rankedBudget("gifts", order: 12, budgeted: 0, spent: -4000),
                rankedBudget("repairs", order: 13, budgeted: 0, spent: 0, carryover: -2500),
            ]
            + (14..<20).map { rankedBudget("quiet\($0)", order: Double($0), budgeted: 1000, spent: -100) }
    }

    @Test func overspentAlertsFindOverspentCategoriesOutsideTheTopTwelveSpenders() {
        let snapshot = WidgetSnapshot.make(
            from: crowdedBudgets, month: "2026-08", balancesHidden: false, generatedAt: Date(), format: { "$\($0)" }
        )

        #expect(!snapshot.rankedCategories.contains { $0.isOverspent })
        #expect(snapshot.overspentCategories.map(\.id) == ["gifts", "repairs"])
    }

    @Test @MainActor func publishedOverspentCountMatchesTheBudgetTabBadge() throws {
        let budgetStore = BudgetStore.previewInstance()
        let store = try makeStore()
        budgetStore.widgetSnapshotStore = store
        // 14 overspent of 20: more than the 12 the ranked list keeps.
        let month = BudgetMonth(month: "2026-08", categoryBudgets: (0..<20).map {
            rankedBudget("c\($0)", order: Double($0), budgeted: 1000, spent: $0 < 14 ? -2000 - $0 : -500)
        })
        budgetStore.widgetBudgetMonth = month

        budgetStore.publishWidgetSnapshot()

        let snapshot = try #require(store.read())
        #expect(month.overspentCount == 14)
        #expect(snapshot.overspentCategories.count == month.overspentCount)
    }

    /// The mask still lists the first 12 in budget order, never the
    /// overspent ones, however many there are.
    @Test func hiddenBalancesKeepOverspentAlertsToTheFirstTwelveInBudgetOrder() {
        let snapshot = WidgetSnapshot.make(
            from: crowdedBudgets, month: "2026-08", balancesHidden: true, generatedAt: Date(), format: { _ in "••••" }
        )

        #expect(snapshot.overspentCategories.map(\.id) == (0..<12).map { "big\($0)" })
    }

    @Test func hiddenBalancesKeepOverspentAlertsInBudgetOrderMasked() {
        let budgets = [
            rankedBudget("small", order: 0, budgeted: 100, spent: -100),
            rankedBudget("over", order: 1, budgeted: 100, spent: -90000),
            rankedBudget("refunds", order: 2, budgeted: 0, spent: 5000),
        ]

        let snapshot = WidgetSnapshot.make(
            from: budgets, month: "2026-08", balancesHidden: true, generatedAt: Date(), format: { _ in "••••" }
        )

        // available still carries raw cents under the mask, so filtering on
        // it would reveal which categories are overspent. Every category
        // shows instead, in budget order, as Top Spending does.
        #expect(snapshot.overspentCategories.map(\.id) == ["small", "over", "refunds"])
        for category in snapshot.overspentCategories {
            #expect(category.formattedAvailable == "••••")
            #expect(category.formattedSpent == "••••")
            #expect(category.formattedBudgeted == "••••")
        }
    }

    // OverspentAlertsWidget's Large / Extra Large Portrait row caps (#862).
    private let overspentLargeLimit = WidgetRowLimits.overspentAlerts.large
    private let overspentExtraLargePortraitLimit = WidgetRowLimits.overspentAlerts.extraLargePortrait

    @Test func overspentAlertsLargeAndExtraLargeShowWorstUpToFamilyLimitWithBudgeted() {
        // c14 spends most, so the worst-first order runs c14 down.
        let budgets = (0..<15).map { rankedBudget("c\($0)", order: Double($0), budgeted: 500, spent: -1000 * ($0 + 1)) }

        let snapshot = WidgetSnapshot.make(
            from: budgets.shuffled(), month: "2026-08", balancesHidden: false, generatedAt: Date(), format: { "$\($0)" }
        )

        let overspent = snapshot.overspentCategories
        #expect(overspent.prefix(overspentLargeLimit).map(\.id) == (7...14).reversed().map { "c\($0)" })
        // rankedCategories' cap of 12 is exactly what Extra Large Portrait shows.
        #expect(overspent.prefix(overspentExtraLargePortraitLimit).map(\.id) == (3...14).reversed().map { "c\($0)" })
        // The budgeted amount beside each row arrives pre-formatted.
        #expect(overspent.prefix(overspentExtraLargePortraitLimit).allSatisfy { $0.formattedBudgeted == "$500" })
        #expect(overspent.first?.formattedAvailable == "$-14500")
    }

    @Test func overspentAlertsLargeAndExtraLargeFewerThanLimitShowsOnlyWhatExists() {
        let budgets = [
            rankedBudget("rent", order: 0, budgeted: 150_000, spent: -150_000),
            rankedBudget("dining", order: 1, budgeted: 20000, spent: -35000),
            rankedBudget("gas", order: 2, budgeted: 10000, spent: -12000),
        ]

        let snapshot = WidgetSnapshot.make(
            from: budgets, month: "2026-08", balancesHidden: false, generatedAt: Date(), format: { "$\($0)" }
        )

        for limit in [overspentLargeLimit, overspentExtraLargePortraitLimit] {
            #expect(snapshot.overspentCategories.prefix(limit).map(\.id) == ["dining", "gas"])
        }
    }

    @Test func hiddenBalancesKeepLargeAndExtraLargeOverspentAlertsInBudgetOrderMasked() {
        // Only c13 is overspent; under the mask every category shows in
        // budget order so the rows can't single it out.
        let budgets = (0..<14).map { rankedBudget("c\($0)", order: Double($0), budgeted: 1000, spent: $0 == 13 ? -90000 : -100) }

        let snapshot = WidgetSnapshot.make(
            from: budgets.shuffled(), month: "2026-08", balancesHidden: true, generatedAt: Date(), format: { _ in "••••" }
        )

        let overspent = snapshot.overspentCategories
        #expect(overspent.prefix(overspentLargeLimit).map(\.id) == (0..<8).map { "c\($0)" })
        #expect(overspent.prefix(overspentExtraLargePortraitLimit).map(\.id) == (0..<12).map { "c\($0)" })
        for category in overspent.prefix(overspentExtraLargePortraitLimit) {
            #expect(category.formattedBudgeted == "••••")
            #expect(category.formattedAvailable == "••••")
        }
    }

    // MARK: - Group 4: Derived rates

    /// Noon on the given day of the current calendar month, so the snapshot
    /// month and generatedAt agree in any time zone.
    private func dayOfMonth(_ day: Int, year: Int = 2026, month: Int = 11) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    /// `spentToDate` is the month-to-date read's figure; nil leaves the read
    /// out, as when it failed.
    private func rateSnapshot(
        day: Int, budgeted: Int, spent: Int, spentToDate: Int? = nil,
        balancesHidden: Bool = false, month: String = "2026-11"
    ) -> WidgetSnapshot {
        let budgetMonth = BudgetMonth(month: month, categoryBudgets: [
            CategoryBudget(
                month: month, categoryId: "c1", categoryName: "Groceries",
                groupId: "g1", groupName: "Everyday", groupSortOrder: 0, categorySortOrder: 0,
                budgeted: budgeted, spent: spent, available: budgeted + spent, carryover: 0
            ),
        ])
        return WidgetSnapshot.make(
            from: budgetMonth.categoryBudgets, month: month, balancesHidden: balancesHidden,
            generatedAt: dayOfMonth(day), format: { balancesHidden ? "••••" : "$\($0)" },
            budgetMonth: budgetMonth,
            monthToDateSpending: spentToDate.map { MonthToDateSpending(thisMonth: ["c1": $0], lastMonth: [:]) }
        )
    }

    /// On Nov 2, $50 spent so far plus $1,450 rent dated Nov 25: the pace is
    /// $25 a day, not the $750 that dividing the whole month by two days gives.
    /// The safe rate still counts the rent, as that money is already committed.
    @Test func ratesPaceOnSpendingToDateNotABillDatedLaterThisMonth() {
        let snapshot = rateSnapshot(day: 2, budgeted: 300_000, spent: -150_000, spentToDate: -5000)

        #expect(snapshot.formattedAverageSpendPerDay == "$2500")
        #expect(snapshot.formattedProjectedSpending == "$75000")
        #expect(snapshot.formattedAverageSpendPerWeek == "$17500")
        // (3,000 budgeted − 1,500 committed) over the 29 days left.
        #expect(snapshot.formattedSafeDailyRate == "$\(150_000 / 29)")
        #expect(snapshot.formattedSafeWeeklyRate == "$\(150_000 / 29 * 7)")
    }

    @Test func ratesMidMonth() {
        // November has 30 days; on the 10th, 10 days have elapsed and 21
        // remain, today included in both.
        let snapshot = rateSnapshot(day: 10, budgeted: 63000, spent: -21000)

        #expect(snapshot.daysElapsed == 10)
        #expect(snapshot.daysRemaining == 21)
        #expect(snapshot.formattedAverageSpendPerDay == "$2100")
        #expect(snapshot.formattedSafeDailyRate == "$2000")
    }

    @Test func ratesOnFirstDayOfMonth() {
        let snapshot = rateSnapshot(day: 1, budgeted: 30000, spent: -500)

        #expect(snapshot.daysElapsed == 1)
        #expect(snapshot.daysRemaining == 30)
        #expect(snapshot.formattedAverageSpendPerDay == "$500")
        #expect(snapshot.formattedSafeDailyRate == "$\(29500 / 30)")
    }

    @Test func lastDayOfMonthLeavesWholeRemainderForToday() {
        let snapshot = rateSnapshot(day: 30, budgeted: 30000, spent: -27000)

        #expect(snapshot.daysElapsed == 30)
        #expect(snapshot.daysRemaining == 1)
        #expect(snapshot.formattedAverageSpendPerDay == "$900")
        #expect(snapshot.formattedSafeDailyRate == "$3000")
    }

    @Test func overspentMonthHasZeroSafeRate() {
        let snapshot = rateSnapshot(day: 15, budgeted: 10000, spent: -20000)

        #expect(snapshot.formattedSafeDailyRate == "$0")
    }

    @Test func netInflowHasZeroAverageSpend() {
        let snapshot = rateSnapshot(day: 15, budgeted: 10000, spent: 5000)

        #expect(snapshot.formattedAverageSpendPerDay == "$0")
    }

    @Test func noBudgetHasNoSafeRateButKeepsAverage() {
        let snapshot = rateSnapshot(day: 10, budgeted: 0, spent: -5000)

        #expect(snapshot.formattedSafeDailyRate == nil)
        #expect(snapshot.formattedAverageSpendPerDay == "$500")
    }

    @Test func noBudgetMonthOrStaleMonthHasNoRates() {
        let noMonth = WidgetSnapshot.make(
            from: [], month: "2026-11", balancesHidden: false, generatedAt: dayOfMonth(10), format: { "$\($0)" }
        )
        let stale = rateSnapshot(day: 10, budgeted: 10000, spent: -100, month: "2026-10")

        for snapshot in [noMonth, stale] {
            #expect(snapshot.daysElapsed == nil)
            #expect(snapshot.daysRemaining == nil)
            #expect(snapshot.formattedAverageSpendPerDay == nil)
            #expect(snapshot.formattedSafeDailyRate == nil)
        }
    }

    @Test(arguments: [10000, 0])
    func hiddenBalancesNeutralizeRates(budgeted: Int) {
        let snapshot = rateSnapshot(day: 10, budgeted: budgeted, spent: -5000, balancesHidden: true)

        #expect(snapshot.formattedAverageSpendPerDay == "••••")
        #expect(snapshot.formattedSafeDailyRate == "••••")
        // Calendar facts carry no amount, so they stay.
        #expect(snapshot.daysElapsed == 10)
        #expect(snapshot.daysRemaining == 21)
    }

    // MARK: Daily Burn Rate widget

    @Test func dailyRatesSurviveStoreRoundTrip() throws {
        let store = try makeStore()
        let snapshot = rateSnapshot(day: 10, budgeted: 63000, spent: -21000)

        try store.write(snapshot)

        let read = try #require(store.read())
        #expect(read.formattedAverageSpendPerDay == "$2100")
        #expect(read.formattedSafeDailyRate == "$2000")
        #expect(read.daysElapsed == 10)
        #expect(read.daysRemaining == 21)
    }

    /// The widget tints the safe rate red off isOverbudget, not a zero safe
    /// rate: a budget spent to the cent floors to 0 too without being over.
    @Test func burnRateRedOnlyWhenOverspent() {
        let over = rateSnapshot(day: 15, budgeted: 10000, spent: -20000)
        let exact = rateSnapshot(day: 15, budgeted: 10000, spent: -10000)
        let under = rateSnapshot(day: 15, budgeted: 10000, spent: -5000)

        #expect(over.formattedSafeDailyRate == "$0" && over.isOverbudget)
        #expect(exact.formattedSafeDailyRate == "$0" && !exact.isOverbudget)
        #expect(!under.isOverbudget)
    }

    @Test func hiddenBalancesMuteOverspentBurnRate() {
        let snapshot = rateSnapshot(day: 15, budgeted: 10000, spent: -20000, balancesHidden: true)

        #expect(!snapshot.isOverbudget)
        #expect(snapshot.formattedSafeDailyRate == "••••")
    }

    /// The widget's empty state keys off a missing average: a snapshot from
    /// before the rates existed, or one without a budget month.
    @Test func burnRateEmptyWithoutAverage() {
        #expect(sampleSnapshot().formattedAverageSpendPerDay == nil)
        let noMonth = WidgetSnapshot.make(
            from: [], month: "2026-11", balancesHidden: false, generatedAt: dayOfMonth(10), format: { "$\($0)" }
        )
        #expect(noMonth.formattedAverageSpendPerDay == nil)
    }

    // MARK: Daily Burn Rate Large / Extra Large Portrait (#862)

    @Test func burnRateLargeProjectsTheMonthAtTheCurrentPace() {
        // 21000 over 10 of November's 30 days paces to 63000.
        let snapshot = rateSnapshot(day: 10, budgeted: 63000, spent: -21000)

        #expect(snapshot.formattedProjectedSpending == "$63000")
    }

    /// The projection works from the unrounded spend: 1000 over 3 days is
    /// 333.33 a day, which paces to 10000 over 30 days, not 333 × 30 = 9990.
    @Test func burnRateProjectionDoesNotCompoundTheRoundedAverage() {
        let snapshot = rateSnapshot(day: 3, budgeted: 30000, spent: -1000)

        #expect(snapshot.formattedAverageSpendPerDay == "$333")
        #expect(snapshot.formattedProjectedSpending == "$10000")
    }

    @Test func burnRateProjectionOnLastDayIsWhatWasSpent() {
        let snapshot = rateSnapshot(day: 30, budgeted: 30000, spent: -27000)

        #expect(snapshot.formattedProjectedSpending == "$27000")
    }

    @Test func burnRateProjectionWithNetInflowIsZero() {
        let snapshot = rateSnapshot(day: 15, budgeted: 10000, spent: 5000)

        #expect(snapshot.formattedProjectedSpending == "$0")
    }

    @Test func burnRateExtraLargeShowsBothRatesPerWeek() {
        let snapshot = rateSnapshot(day: 10, budgeted: 63000, spent: -21000)

        #expect(snapshot.formattedAverageSpendPerWeek == "$14700")
        #expect(snapshot.formattedSafeWeeklyRate == "$14000")
    }

    @Test func burnRateWeeklySafeRateIsNilWithNothingBudgeted() {
        let snapshot = rateSnapshot(day: 10, budgeted: 0, spent: -5000)

        #expect(snapshot.formattedSafeWeeklyRate == nil)
        #expect(snapshot.formattedAverageSpendPerWeek == "$3500")
        #expect(snapshot.formattedProjectedSpending == "$15000")
    }

    @Test func burnRateWeeklySafeRateIsZeroWhenOverspent() {
        let snapshot = rateSnapshot(day: 15, budgeted: 10000, spent: -20000)

        #expect(snapshot.formattedSafeWeeklyRate == "$0")
    }

    @Test(arguments: [(1, 1.0 / 30), (10, 10.0 / 30), (30, 1.0)])
    func burnRateMonthProgressIsDaysElapsedOverDaysInMonth(day: Int, expected: Double) throws {
        let snapshot = rateSnapshot(day: day, budgeted: 10000, spent: -100)

        let progress = try #require(snapshot.monthProgress)
        #expect(abs(progress - expected) < 1e-9)
    }

    /// February 2028 has 29 days, so the denominator follows the month.
    @Test func burnRateMonthProgressFollowsTheMonthLength() throws {
        let budgetMonth = spendingMonth("2028-02", spent: -100)
        let snapshot = WidgetSnapshot.make(
            from: [], month: "2028-02", balancesHidden: false,
            generatedAt: dayOfMonth(29, year: 2028, month: 2), format: { "$\($0)" },
            budgetMonth: budgetMonth
        )

        #expect(snapshot.daysRemaining == 1)
        #expect(try #require(snapshot.monthProgress) == 1.0)
    }

    @Test func burnRateLargeAndExtraLargeHaveNothingWithoutRates() throws {
        let noMonth = WidgetSnapshot.make(
            from: [], month: "2026-11", balancesHidden: false, generatedAt: dayOfMonth(10), format: { "$\($0)" }
        )
        let stale = rateSnapshot(day: 10, budgeted: 10000, spent: -100, month: "2026-10")
        let legacy = try JSONDecoder().decode(WidgetSnapshot.self, from: Data("""
        {"month":"2026-11","generatedAt":0,"balancesHidden":false,"categories":[],
         "daysElapsed":10,"daysRemaining":21,"formattedAverageSpendPerDay":"$1.00"}
        """.utf8))

        for snapshot in [noMonth, stale] {
            #expect(snapshot.formattedProjectedSpending == nil)
            #expect(snapshot.formattedAverageSpendPerWeek == nil)
            #expect(snapshot.formattedSafeWeeklyRate == nil)
            #expect(snapshot.monthProgress == nil)
        }
        // Written before the Large fields existed: the amounts are absent, but
        // month progress only needs the day counts that were already there.
        #expect(legacy.formattedProjectedSpending == nil)
        #expect(legacy.formattedAverageSpendPerWeek == nil)
        #expect(legacy.formattedSafeWeeklyRate == nil)
        #expect(legacy.monthProgress == 10.0 / 30)
    }

    @Test func burnRateLargeAndExtraLargeSurviveStoreRoundTrip() throws {
        let store = try makeStore()
        try store.write(rateSnapshot(day: 10, budgeted: 63000, spent: -21000))

        let read = try #require(store.read())
        #expect(read.formattedProjectedSpending == "$63000")
        #expect(read.formattedAverageSpendPerWeek == "$14700")
        #expect(read.formattedSafeWeeklyRate == "$14000")
        #expect(read.monthProgress == 10.0 / 30)
    }

    @Test(arguments: [10000, 0])
    func hiddenBalancesMaskLargeAndExtraLargeBurnRateAmounts(budgeted: Int) {
        let snapshot = rateSnapshot(day: 10, budgeted: budgeted, spent: -5000, balancesHidden: true)

        #expect(snapshot.formattedProjectedSpending == "••••")
        #expect(snapshot.formattedAverageSpendPerWeek == "••••")
        // Masked even with nothing budgeted, so a missing rate can't reveal that.
        #expect(snapshot.formattedSafeWeeklyRate == "••••")
        // Calendar facts carry no amount, so progress stays.
        #expect(snapshot.monthProgress == 10.0 / 30)
    }

    @Test @MainActor func publishMasksLargeAndExtraLargeBurnRateAmountsWhenHidden() throws {
        let budgetStore = BudgetStore.previewInstance()
        let store = try makeStore()
        budgetStore.widgetSnapshotStore = store
        budgetStore.hideBalances = true
        defer { budgetStore.hideBalances = false }
        let month = Calendar.current.dateComponents([.year, .month], from: Date())
        budgetStore.widgetBudgetMonth = spendingMonth(
            String(format: "%04d-%02d", month.year ?? 0, month.month ?? 0), spent: -60000
        )

        budgetStore.publishWidgetSnapshot()

        let snapshot = try #require(store.read())
        let mask = BudgetStore.hiddenBalanceText
        #expect(snapshot.formattedProjectedSpending == mask)
        #expect(snapshot.formattedAverageSpendPerWeek == mask)
        #expect(snapshot.formattedSafeWeeklyRate == mask)
        #expect(snapshot.monthProgress != nil)
    }

    // MARK: Spending vs Last Month Large / Extra Large Portrait (#862)

    // SpendingComparisonWidget's Large / Extra Large Portrait mover counts,
    // from the table it reads.
    private let moverLargeLimit = WidgetRowLimits.spendingMovers.large
    private let moverExtraLargePortraitLimit = WidgetRowLimits.spendingMovers.extraLargePortrait

    private func moverSnapshot(
        _ budgets: [CategoryBudget], last: [String: Int], balancesHidden: Bool = false
    ) -> WidgetSnapshot {
        WidgetSnapshot.make(
            from: budgets, month: "2026-08", balancesHidden: balancesHidden, generatedAt: Date(),
            format: { balancesHidden ? "••••" : "$\($0)" },
            budgetMonth: BudgetMonth(month: "2026-08", categoryBudgets: budgets),
            monthToDateSpending: toDate(budgets, last: last)
        )
    }

    /// food up 200, fun down 30, new up 20 (nothing last month), idle unchanged.
    private var moverBudgets: [CategoryBudget] {
        [
            rankedBudget("idle", order: 0, budgeted: 0, spent: 0),
            rankedBudget("fun", order: 1, budgeted: 0, spent: -5000),
            rankedBudget("new", order: 2, budgeted: 0, spent: -2000),
            rankedBudget("food", order: 3, budgeted: 0, spent: -30000),
        ]
    }

    private let moverLastMonth = ["fun": -8000, "food": -10000]

    @Test func categoryDifferenceComparesWithLastMonthToDate() {
        let snapshot = moverSnapshot(moverBudgets, last: moverLastMonth)
        let byId = Dictionary(uniqueKeysWithValues: snapshot.categories.map { ($0.id, $0) })

        // Positive means spending more this month, like spendingDifference.
        #expect(byId["food"]?.spendingDifference == 20000)
        #expect(byId["food"]?.formattedSpendingDifference == "$20000")
        #expect(byId["fun"]?.spendingDifference == -3000)
        #expect(byId["fun"]?.formattedSpendingDifference == "$-3000")
        // No rows last month compares against nothing spent.
        #expect(byId["new"]?.spendingDifference == 2000)
        #expect(byId["idle"]?.spendingDifference == 0)
        // The per-category figures add up to the headline difference.
        #expect(snapshot.categories.compactMap(\.spendingDifference).reduce(0, +) == snapshot.spendingDifference)
    }

    @Test func moversRankByLargestChangeEitherWayAndDropUnchanged() {
        let snapshot = moverSnapshot(moverBudgets, last: moverLastMonth)

        // Large's top mover is the biggest swing, up or down.
        #expect(snapshot.categoryMovers(limit: moverLargeLimit).map(\.id) == ["food"])
        // Fewer movers than Extra Large's limit shows only what moved.
        #expect(snapshot.categoryMovers(limit: moverExtraLargePortraitLimit).map(\.id) == ["food", "fun", "new"])
    }

    @Test func moversCapAtTheLimitAndTiesKeepBudgetOrder() {
        let budgets = (0..<6).map { rankedBudget("c\($0)", order: Double($0), budgeted: 0, spent: $0 < 2 ? -900 : -100 * $0) }

        // One zero row last month is enough to switch the comparison on.
        let snapshot = moverSnapshot(budgets.shuffled(), last: ["c0": 0])

        #expect(snapshot.categoryMovers(limit: moverExtraLargePortraitLimit).map(\.id) == ["c0", "c1", "c5", "c4"])
    }

    @Test func moverTrendFollowsEachCategorysDifference() throws {
        let snapshot = moverSnapshot(moverBudgets, last: moverLastMonth)
        let movers = snapshot.categoryMovers(limit: moverExtraLargePortraitLimit)

        #expect(movers.map { snapshot.spendingTrend(of: $0) } == [.more, .less, .more])
        let idle = try #require(snapshot.categories.first { $0.id == "idle" })
        #expect(snapshot.spendingTrend(of: idle) == .same)
    }

    @Test func noLastMonthDataLeavesNoMovers() throws {
        let noComparison = WidgetSnapshot.make(
            from: moverBudgets, month: "2026-08", balancesHidden: false, generatedAt: Date(), format: { "$\($0)" },
            budgetMonth: BudgetMonth(month: "2026-08", categoryBudgets: moverBudgets)
        )
        let legacy = try JSONDecoder().decode(WidgetSnapshot.self, from: Data("""
        {"month":"2026-08","generatedAt":0,"balancesHidden":false,
         "categories":[{"id":"a","name":"A","available":0,"formattedAvailable":"$0","spent":-100}]}
        """.utf8))

        for snapshot in [noComparison, legacy] {
            #expect(snapshot.categories.allSatisfy { $0.spendingDifference == nil && $0.formattedSpendingDifference == nil })
            #expect(snapshot.categoryMovers(limit: moverLargeLimit).isEmpty)
            #expect(snapshot.categoryMovers(limit: moverExtraLargePortraitLimit).isEmpty)
        }
    }

    @Test func hiddenBalancesMaskMoversAndKeepBudgetOrder() {
        let snapshot = moverSnapshot(moverBudgets, last: moverLastMonth, balancesHidden: true)
        let movers = snapshot.categoryMovers(limit: moverExtraLargePortraitLimit)

        // Ranking or dropping the unchanged would reveal which categories moved
        // most, so hidden keeps budget order, unchanged ones included.
        #expect(movers.map(\.id) == ["idle", "fun", "new", "food"])
        #expect(snapshot.categoryMovers(limit: moverLargeLimit).map(\.id) == ["idle"])
        for mover in movers {
            #expect(mover.spendingDifference == 0)
            #expect(mover.formattedSpendingDifference == "••••")
            // No arrow or red to leak the direction.
            #expect(snapshot.spendingTrend(of: mover) == nil)
        }
    }

    @Test func moversSurviveStoreRoundTrip() throws {
        let store = try makeStore()
        let snapshot = moverSnapshot(moverBudgets, last: moverLastMonth)
        try store.write(snapshot)

        let read = try #require(store.read())
        #expect(read.categoryMovers(limit: moverExtraLargePortraitLimit) == snapshot.categoryMovers(limit: moverExtraLargePortraitLimit))
    }

    @Test @MainActor func publishFillsCategoryMoversFromTheStore() throws {
        let budgetStore = BudgetStore.previewInstance()
        let store = try makeStore()
        budgetStore.widgetSnapshotStore = store
        budgetStore.widgetMonthToDateSpending = toDate(moverBudgets, last: moverLastMonth)
        budgetStore.widgetBudgetMonth = BudgetMonth(month: "2026-08", categoryBudgets: moverBudgets)

        budgetStore.publishWidgetSnapshot()

        let snapshot = try #require(store.read())
        let top = try #require(snapshot.categoryMovers(limit: moverLargeLimit).first)
        #expect(top.id == "food")
        #expect(top.formattedSpendingDifference == budgetStore.displayBalance(20000))
        #expect(snapshot.formattedTotalSpendingLastMonth == budgetStore.displayBalance(18000))
    }

    // MARK: Overview Extra Large Portrait (#862)

    // OverviewProvider's fixed section sizes, from the table it reads; the
    // widget is Extra Large Portrait only, so one size per section.
    private let overviewAccountLimit = WidgetRowLimits.overview.accounts
    private let overviewCategoryLimit = WidgetRowLimits.overview.categories
    private let overviewTransactionLimit = WidgetRowLimits.overview.transactions
    private let overviewBillLimit = WidgetRowLimits.overview.bills

    private func overviewSnapshot(balancesHidden: Bool = false) -> WidgetSnapshot {
        let budgets = (0..<6).map { index in
            CategoryBudget(
                month: "2026-08", categoryId: "c\(index)", categoryName: "Category \(index)",
                groupId: "g1", groupName: "Everyday", groupSortOrder: 0, categorySortOrder: Double(index),
                budgeted: 50000, spent: -30000, available: 20000, carryover: 0
            )
        }
        let accounts = (0..<5).map {
            Account(id: "a\($0)", name: "Account \($0)", type: .checking, offBudget: $0 == 1, closed: false, sortOrder: $0, balance: 10000)
        }
        return WidgetSnapshot.make(
            from: budgets, month: "2026-08", balancesHidden: balancesHidden, generatedAt: Date(),
            format: { balancesHidden ? "••••" : "$\($0)" },
            accounts: accounts,
            budgetMonth: BudgetMonth(month: "2026-08", categoryBudgets: budgets, toBudget: 62900),
            schedules: billSchedules(count: 5).reversed(),
            transactions: (1...5).map { makeTransaction(id: "t\($0)", date: 20_260_800 + $0, amount: -100) }
        )
    }

    @Test func overviewFillsEverySectionToItsFixedSize() {
        let snapshot = overviewSnapshot()

        // Headline: Net Worth counts the off-budget account the rows skip.
        #expect(snapshot.formattedNetWorth == "$50000")
        #expect(snapshot.formattedToBudget == "$62900")
        #expect(snapshot.formattedTotalSpending == "$180000")
        #expect(snapshot.formattedTotalBudgeted == "$300000")
        #expect(snapshot.spentFraction == 0.6)

        #expect(snapshot.accounts(matching: [], limit: overviewAccountLimit).map(\.id) == ["a0", "a2", "a3"])
        #expect(snapshot.categories(matching: [], limit: overviewCategoryLimit).map(\.id) == ["c0", "c1", "c2", "c3"])
        #expect(snapshot.latestTransactions(limit: overviewTransactionLimit).map(\.id) == ["t5", "t4", "t3"])
        #expect(snapshot.nextBills(limit: overviewBillLimit).map(\.id) == ["s1", "s2", "s3"])
    }

    @Test func overviewShowsChosenCategoriesInChosenOrderCappedAtFour() {
        let snapshot = overviewSnapshot()

        #expect(snapshot.categories(matching: ["c5", "c0", "c3", "c1", "c2"], limit: overviewCategoryLimit).map(\.id) == ["c5", "c0", "c3", "c1"])
        #expect(snapshot.categories(matching: ["c4", "gone"], limit: overviewCategoryLimit).map(\.id) == ["c4"])
    }

    /// Each section's own empty line covers this: a budget with no accounts,
    /// transactions or bills still shows its headline and categories.
    @Test func overviewSectionsWithoutDataAreEmpty() {
        let snapshot = sampleSnapshot()

        #expect(snapshot.accounts(matching: [], limit: overviewAccountLimit).isEmpty)
        #expect(snapshot.latestTransactions(limit: overviewTransactionLimit).isEmpty)
        #expect(snapshot.nextBills(limit: overviewBillLimit).isEmpty)
        #expect(snapshot.categories(matching: [], limit: overviewCategoryLimit).count == 3)
    }

    @Test @MainActor func hiddenBalancesMaskEveryOverviewAmount() throws {
        let budgetStore = BudgetStore.previewInstance()
        let store = try makeStore()
        budgetStore.widgetSnapshotStore = store
        budgetStore.accounts = [onBudgetAccount]
        budgetStore.schedules = billSchedules(count: 5)
        budgetStore.transactions = (1...5).map { makeTransaction(id: "t\($0)", date: 20_260_800 + $0, amount: -100) }
        budgetStore.widgetBudgetMonth = spendingMonth("2026-08", spent: -42000)
        budgetStore.hideBalances = true
        defer { budgetStore.hideBalances = false }

        let snapshot = try #require(store.read())
        let hidden = BudgetStore.hiddenBalanceText

        #expect(snapshot.balancesHidden)
        #expect(snapshot.formattedNetWorth == hidden)
        #expect(snapshot.formattedTotalSpending == hidden)
        #expect(snapshot.formattedTotalBudgeted == hidden)
        #expect(snapshot.spentFraction == 0)
        #expect(snapshot.accounts(matching: [], limit: overviewAccountLimit).allSatisfy { $0.formattedBalance == hidden })
        #expect(snapshot.categories(matching: [], limit: overviewCategoryLimit).allSatisfy { $0.formattedAvailable == hidden })
        #expect(snapshot.latestTransactions(limit: overviewTransactionLimit).allSatisfy { $0.formattedAmount == hidden && $0.amount == 0 })
        let bills = snapshot.nextBills(limit: overviewBillLimit)
        #expect(bills.count == overviewBillLimit)
        #expect(bills.allSatisfy { $0.formattedAmount == hidden })
    }
}
