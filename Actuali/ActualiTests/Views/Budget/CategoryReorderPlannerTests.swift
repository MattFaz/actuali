import CoreGraphics
import Testing
@testable import Actuali

/// Where a dragged category lands in the Clean budget table, and the order
/// that results.
struct CategoryReorderPlannerTests {
    typealias Entry = CategoryReorderPlanner.Entry
    typealias Slot = CategoryReorderPlanner.Slot

    /// Two groups of 100pt rows with a 60pt header gap between them:
    /// A: a1 0–100, a2 100–200, a3 200–300; B: b1 360–460, b2 460–560.
    private let arrangement = [
        Entry(id: "A", ids: ["a1", "a2", "a3"]),
        Entry(id: "B", ids: ["b1", "b2"]),
    ]

    private let frames: [String: CGRect] = [
        "a1": CGRect(x: 0, y: 0, width: 300, height: 100),
        "a2": CGRect(x: 0, y: 100, width: 300, height: 100),
        "a3": CGRect(x: 0, y: 200, width: 300, height: 100),
        "b1": CGRect(x: 0, y: 360, width: 300, height: 100),
        "b2": CGRect(x: 0, y: 460, width: 300, height: 100),
    ]

    private func destination(_ dragged: String, _ centerY: CGFloat, in arrangement: [Entry]? = nil) -> Slot? {
        CategoryReorderPlanner.destination(
            dragged: dragged,
            centerY: centerY,
            arrangement: arrangement ?? self.arrangement,
            frames: frames
        )
    }

    @Test func draggingUpWithinAGroupPassesTheRowsAboveIt() {
        // a3's centre at 120 is above a2's middle (150), below a1's (50).
        #expect(destination("a3", 120) == Slot(groupId: "A", index: 1))
        #expect(destination("a3", 40) == Slot(groupId: "A", index: 0))
    }

    @Test func draggingDownWithinAGroupPassesTheRowsBelowIt() {
        #expect(destination("a1", 290) == Slot(groupId: "A", index: 2))
        #expect(destination("a1", 160) == Slot(groupId: "A", index: 1))
    }

    @Test func aRowStaysPutWhileItsCentreIsOverItsOwnSlot() {
        #expect(destination("a2", 150) == Slot(groupId: "A", index: 1))
        #expect(CategoryReorderPlanner.slot(of: "a2", in: arrangement) == Slot(groupId: "A", index: 1))
    }

    @Test func draggingIntoAnotherGroupLandsAmongItsRows() {
        #expect(destination("a2", 400) == Slot(groupId: "B", index: 0))
        #expect(destination("a2", 520) == Slot(groupId: "B", index: 2))
        #expect(destination("a2", 440) == Slot(groupId: "B", index: 1))
    }

    @Test func theGapBetweenGroupsGoesToTheNearerCard() {
        // 320 is 20 below A's card and 40 above B's: the end of A.
        #expect(destination("b1", 320) == Slot(groupId: "A", index: 3))
        // 345 is 45 below A and 15 above B: the start of B.
        #expect(destination("a1", 345) == Slot(groupId: "B", index: 0))
    }

    @Test func pastTheEndsOfTheTableItGoesToTheFirstOrLastGroup() {
        #expect(destination("a2", -80) == Slot(groupId: "A", index: 0))
        #expect(destination("a2", 900) == Slot(groupId: "B", index: 2))
    }

    @Test func aGroupItIsAloneInStillCountsAsACard() {
        let alone = [Entry(id: "A", ids: ["a1"]), Entry(id: "B", ids: ["b1", "b2"])]
        #expect(destination("a1", 50, in: alone) == Slot(groupId: "A", index: 0))
    }

    @Test func noMeasuredRowsMeansNoDestination() {
        #expect(CategoryReorderPlanner.destination(
            dragged: "a1", centerY: 10, arrangement: arrangement, frames: [:]
        ) == nil)
    }

    @Test func movedTakesTheRowOutAndPutsItAtTheSlot() {
        let withinGroup = CategoryReorderPlanner.moved(arrangement, dragged: "a3", to: Slot(groupId: "A", index: 0))
        #expect(withinGroup == [Entry(id: "A", ids: ["a3", "a1", "a2"]), Entry(id: "B", ids: ["b1", "b2"])])

        let acrossGroups = CategoryReorderPlanner.moved(arrangement, dragged: "a1", to: Slot(groupId: "B", index: 2))
        #expect(acrossGroups == [Entry(id: "A", ids: ["a2", "a3"]), Entry(id: "B", ids: ["b1", "b2", "a1"])])
    }

    @Test func movedIgnoresAnUnknownGroupAndClampsTheIndex() {
        #expect(CategoryReorderPlanner.moved(arrangement, dragged: "a1", to: Slot(groupId: "Z", index: 0)) == arrangement)
        let clamped = CategoryReorderPlanner.moved(arrangement, dragged: "a1", to: Slot(groupId: "B", index: 99))
        #expect(clamped[1].ids == ["b1", "b2", "a1"])
    }

    @Test func theSavedTargetIsTheRowNowBelowIt() {
        let moved = CategoryReorderPlanner.moved(arrangement, dragged: "a3", to: Slot(groupId: "B", index: 1))
        let target = CategoryReorderPlanner.target(of: "a3", in: moved)
        #expect(target?.groupId == "B")
        #expect(target?.before == "b2")
    }

    @Test func theLastRowInAGroupSavesWithoutATarget() {
        let target = CategoryReorderPlanner.target(of: "a1", in: CategoryReorderPlanner.moved(
            arrangement, dragged: "a1", to: Slot(groupId: "A", index: 2)
        ))
        #expect(target?.groupId == "A")
        #expect(target?.before == nil)
    }

    // MARK: - Steps (VoiceOver)

    @Test func aStepMovesWithinTheGroup() {
        #expect(CategoryReorderPlanner.step(-1, of: "a2", in: arrangement) == Slot(groupId: "A", index: 0))
        #expect(CategoryReorderPlanner.step(1, of: "a2", in: arrangement) == Slot(groupId: "A", index: 2))
    }

    @Test func aStepAtAGroupEdgeSpillsIntoTheNeighbouringGroup() {
        // Up from the top of B lands at the end of A; down from the bottom of A at the start of B.
        #expect(CategoryReorderPlanner.step(-1, of: "b1", in: arrangement) == Slot(groupId: "A", index: 3))
        #expect(CategoryReorderPlanner.step(1, of: "a3", in: arrangement) == Slot(groupId: "B", index: 0))
    }

    @Test func aStepOffTheTableDoesNothing() {
        #expect(CategoryReorderPlanner.step(-1, of: "a1", in: arrangement) == nil)
        #expect(CategoryReorderPlanner.step(1, of: "b2", in: arrangement) == nil)
    }

    // MARK: - Groups

    private let groupFrames: [String: CGRect] = [
        "header-A": CGRect(x: 0, y: 0, width: 300, height: 50),
        "header-B": CGRect(x: 0, y: 50, width: 300, height: 50),
        "header-C": CGRect(x: 0, y: 100, width: 300, height: 50),
    ]

    @Test func aDraggedGroupCountsTheHeadersAboveItsCentre() {
        let order = ["A", "B", "C"]
        // C's centre over A: above both other headers' middles.
        #expect(CategoryReorderPlanner.groupDestination(dragged: "C", centerY: 20, order: order, frames: groupFrames) == 0)
        // Between A's middle (25) and B's (75).
        #expect(CategoryReorderPlanner.groupDestination(dragged: "C", centerY: 60, order: order, frames: groupFrames) == 1)
        #expect(CategoryReorderPlanner.groupDestination(dragged: "A", centerY: 140, order: order, frames: groupFrames) == 2)
    }

    @Test func movedGroupTakesTheGroupOutAndPutsItAtTheIndex() {
        #expect(CategoryReorderPlanner.movedGroup(["A", "B", "C"], dragged: "C", to: 0) == ["C", "A", "B"])
        #expect(CategoryReorderPlanner.movedGroup(["A", "B", "C"], dragged: "A", to: 2) == ["B", "C", "A"])
        #expect(CategoryReorderPlanner.movedGroup(["A", "B", "C"], dragged: "B", to: 99) == ["A", "C", "B"])
    }

    @Test func aGroupSavesBeforeTheGroupNowBelowIt() {
        #expect(CategoryReorderPlanner.groupTarget(of: "C", in: ["C", "A", "B"]) == "A")
        #expect(CategoryReorderPlanner.groupTarget(of: "A", in: ["B", "C", "A"]) == nil)
    }

    @Test func aGroupStepStaysWithinTheGroups() {
        #expect(CategoryReorderPlanner.groupStep(-1, of: "B", in: ["A", "B", "C"]) == 0)
        #expect(CategoryReorderPlanner.groupStep(1, of: "B", in: ["A", "B", "C"]) == 2)
        #expect(CategoryReorderPlanner.groupStep(-1, of: "A", in: ["A", "B", "C"]) == nil)
        #expect(CategoryReorderPlanner.groupStep(1, of: "C", in: ["A", "B", "C"]) == nil)
    }
}
