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
                WidgetCategoryBalance(id: "a", name: "Dining Out", available: 12_345, formattedAvailable: "$123.45"),
                WidgetCategoryBalance(id: "b", name: "Groceries", available: -2_000, formattedAvailable: "-$20.00"),
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

    // MARK: - BudgetStore publishing

    private func makeBudget(id: String, name: String, month: String) -> CategoryBudget {
        CategoryBudget(
            month: month, categoryId: id, categoryName: name,
            groupId: "g1", groupName: "Everyday", groupSortOrder: 0, categorySortOrder: 0,
            budgeted: 10_000, spent: -5_000, available: 5_000, carryover: 0
        )
    }

    @Test @MainActor func publishUsesWidgetMonthNotBrowsedMonth() throws {
        let budgetStore = BudgetStore.previewInstance()
        let store = try makeStore()
        budgetStore.widgetSnapshotStore = store
        // The user is browsing January's history while the calendar says August.
        budgetStore.currentBudgetMonth = BudgetMonth(
            month: "2026-01", categoryBudgets: [makeBudget(id: "old", name: "Old", month: "2026-01")])
        budgetStore.widgetBudgetMonth = BudgetMonth(
            month: "2026-08", categoryBudgets: [makeBudget(id: "dining", name: "Dining Out", month: "2026-08")])

        budgetStore.publishWidgetSnapshot()

        #expect(store.read()?.categories.map(\.id) == ["dining"])
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
            month: "2026-08", categoryBudgets: [makeBudget(id: "dining", name: "Dining Out", month: "2026-08")])
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
                budgeted: 40_000, spent: -42_000, available: -2_000, carryover: 0
            ),
            CategoryBudget(
                month: "2026-08", categoryId: "rent", categoryName: "Rent",
                groupId: "g0", groupName: "Bills", groupSortOrder: -1, categorySortOrder: 5,
                budgeted: 100_000, spent: -100_000, available: 0, carryover: 0
            ),
            CategoryBudget(
                month: "2026-08", categoryId: "dining", categoryName: "Dining Out",
                groupId: "g1", groupName: "Everyday", groupSortOrder: 0, categorySortOrder: 0,
                budgeted: 30_000, spent: -17_655, available: 12_345, carryover: 0
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
            WidgetCategoryBalance(id: "rent", name: "Rent", available: 0, formattedAvailable: "<0>"),
            WidgetCategoryBalance(id: "dining", name: "Dining Out", available: 12_345, formattedAvailable: "<12345>"),
            WidgetCategoryBalance(id: "grocery", name: "Groceries", available: -2_000, formattedAvailable: "<-2000>"),
        ])
    }
}
