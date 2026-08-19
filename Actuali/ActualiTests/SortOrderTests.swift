import Testing
@testable import Actuali

/// Pins `SortOrder.shove` to upstream `shoveSortOrders`
/// (packages/loot-core/src/server/db/sort.ts), which decides where a new
/// category lands and which siblings have to move for it.
struct SortOrderTests {

    private func position(_ id: String, _ sortOrder: Double) -> SortOrder.Position {
        SortOrder.Position(id: id, sortOrder: sortOrder)
    }

    @Test func firstRowOfAnEmptyListTakesTheIncrement() {
        let placement = SortOrder.shove([], before: nil)

        #expect(placement.sortOrder == SortOrder.increment)
        #expect(placement.moved.isEmpty)
    }

    @Test func noTargetAppendsAfterTheLastRow() {
        let placement = SortOrder.shove(
            [position("a", 16384), position("b", 32768)],
            before: nil
        )

        #expect(placement.sortOrder == 32768 + SortOrder.increment)
        #expect(placement.moved.isEmpty)
    }

    @Test func unknownTargetAppendsRatherThanFailing() {
        let placement = SortOrder.shove([position("a", 16384)], before: "gone")

        #expect(placement.sortOrder == 16384 + SortOrder.increment)
        #expect(placement.moved.isEmpty)
    }

    @Test func insertingBeforeTheFirstRowHalvesItsOrder() {
        let placement = SortOrder.shove(
            [position("a", 16384), position("b", 32768)],
            before: "a"
        )

        #expect(placement.sortOrder == 8192)
        #expect(placement.moved.isEmpty)
    }

    @Test func insertingBetweenTwoRowsTakesTheMidpoint() {
        let placement = SortOrder.shove(
            [position("a", 16384), position("b", 32768)],
            before: "b"
        )

        #expect(placement.sortOrder == 24576)
        #expect(placement.moved.isEmpty)
    }

    /// Repeated inserts at the top halve the gap each time; once it closes to
    /// 2 there's no midpoint left and upstream pushes the list up instead.
    @Test func aClosedGapShovesTheRowsBelowUp() {
        let placement = SortOrder.shove([position("a", 2)], before: "a")

        #expect(placement.moved == [SortOrder.Position(id: "a", sortOrder: 2 + SortOrder.increment)])
        // Measured against the pre-shove value, like upstream — "a" has moved
        // to 16386, so 1 still puts the new row first.
        #expect(placement.sortOrder == 1)
    }

    @Test func theShoveCascadesThroughEveryCrowdedRow() {
        let placement = SortOrder.shove(
            [position("a", 1), position("b", 2), position("c", 3)],
            before: "a"
        )

        #expect(placement.moved == [
            SortOrder.Position(id: "a", sortOrder: 16385),
            SortOrder.Position(id: "b", sortOrder: 32769),
            SortOrder.Position(id: "c", sortOrder: 49153)
        ])
        #expect(placement.sortOrder == 0.5)
    }

    /// A row that already sits above the order being handed out has room of
    /// its own, so the cascade stops there instead of renumbering the list.
    @Test func theShoveStopsAtTheFirstRowWithRoom() {
        let placement = SortOrder.shove(
            [position("a", 1), position("b", 100_000)],
            before: "a"
        )

        #expect(placement.moved == [SortOrder.Position(id: "a", sortOrder: 16385)])
        #expect(placement.sortOrder == 0.5)
    }
}
