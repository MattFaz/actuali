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

    @Test func readReturnsNilForNewerSchemaVersion() throws {
        let store = try makeStore()
        var snapshot = sampleSnapshot()
        snapshot.schemaVersion = WidgetSnapshot.currentSchemaVersion + 1

        try store.write(snapshot)

        #expect(store.read() == nil)
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

    // MARK: - Building from category budgets

    @Test func makeFromCategoryBudgetsMapsFieldsAndFormats() {
        let budgets = [
            CategoryBudget(
                month: "2026-08", categoryId: "dining", categoryName: "Dining Out",
                groupId: "g1", groupName: "Everyday", groupSortOrder: 0, categorySortOrder: 0,
                budgeted: 30_000, spent: -17_655, available: 12_345, carryover: 0
            ),
            CategoryBudget(
                month: "2026-08", categoryId: "grocery", categoryName: "Groceries",
                groupId: "g1", groupName: "Everyday", groupSortOrder: 0, categorySortOrder: 1,
                budgeted: 40_000, spent: -42_000, available: -2_000, carryover: 0
            ),
        ]
        let generated = Date(timeIntervalSince1970: 1_750_000_000)

        let snapshot = WidgetSnapshot.make(
            from: budgets,
            balancesHidden: false,
            generatedAt: generated
        ) { cents in "<\(cents)>" }

        #expect(snapshot.generatedAt == generated)
        #expect(snapshot.balancesHidden == false)
        #expect(snapshot.categories == [
            WidgetCategoryBalance(id: "dining", name: "Dining Out", available: 12_345, formattedAvailable: "<12345>"),
            WidgetCategoryBalance(id: "grocery", name: "Groceries", available: -2_000, formattedAvailable: "<-2000>"),
        ])
    }
}
