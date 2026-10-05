import CoreGraphics
import Testing
@testable import Actuali

@MainActor
struct CategoryReorderControllerTests {
    private func groups(_ ids: [String] = ["x", "y", "z"]) -> [BudgetView.CategoryGroupSection] {
        let categories = ids.map { id in
            CategoryBudget(
                month: "2026-10", categoryId: id, categoryName: id,
                groupId: "A", groupName: "A", groupSortOrder: 1,
                categorySortOrder: 1, budgeted: 0, spent: 0,
                available: 0, carryover: 0
            )
        }
        return [
            .init(id: "A", name: "A", isHidden: false, categories: categories, totals: CategoryGroupTotals(categories)),
            .init(id: "B", name: "B", isHidden: false, categories: [], totals: CategoryGroupTotals([])),
        ]
    }

    private func controller() -> CategoryReorderController {
        let controller = CategoryReorderController()
        controller.rowFrames = Dictionary(uniqueKeysWithValues: ["x", "y", "z"].enumerated().map {
            ($0.element, CGRect(x: 0, y: ($0.offset + 1) * 54, width: 300, height: 54))
        })
        controller.rowFrames["header-A"] = CGRect(x: 0, y: 0, width: 300, height: 44)
        controller.rowFrames["header-B"] = CGRect(x: 0, y: 216, width: 300, height: 44)
        return controller
    }

    @Test func aPendingCategoryDropBlocksOtherMovesUntilRefreshCompletes() {
        let controller = controller()
        let original = groups()
        var drops: [CategoryMove] = []
        var groupDrops: [CategoryGroupMove] = []
        controller.onDrop = { drops.append($0) }
        controller.onDropGroup = { groupDrops.append($0) }

        controller.touch(id: "z", viewportY: 189) { original }
        controller.touch(id: "z", viewportY: 54) { original }
        // No measured landing frame bypasses the cosmetic settling delay.
        controller.rowFrames.removeValue(forKey: "z")
        controller.finish(ifLifted: "z")
        #expect(drops == [CategoryMove(id: "z", groupId: "A", before: "x")])

        controller.touch(id: "y", viewportY: 135) { original }
        controller.touchGroup(id: "B", viewportY: 243) { original }
        controller.step(-1, of: "y", groups: original)
        controller.stepGroup(-1, of: "B", groups: original)
        #expect(!controller.isDragging)
        #expect(controller.arrangement.first?.ids == ["z", "x", "y"])
        #expect(drops.count == 1)
        #expect(groupDrops.isEmpty)

        controller.clearPreview()
        let saved = groups(["z", "x", "y"])
        controller.touch(id: "y", viewportY: 135) { saved }
        controller.touch(id: "y", viewportY: 0) { saved }
        controller.rowFrames.removeValue(forKey: "y")
        controller.finish(ifLifted: "y")
        #expect(drops.last == CategoryMove(id: "y", groupId: "A", before: "z"))
        controller.clearPreview()
    }

    @Test func aPendingGroupDropBlocksOtherMovesUntilRefreshCompletes() {
        let controller = controller()
        let original = groups()
        var drops: [CategoryMove] = []
        var groupDrops: [CategoryGroupMove] = []
        controller.onDrop = { drops.append($0) }
        controller.onDropGroup = { groupDrops.append($0) }

        controller.touchGroup(id: "B", viewportY: 243) { original }
        controller.touchGroup(id: "B", viewportY: 0) { original }
        controller.rowFrames.removeValue(forKey: "header-B")
        controller.finishGroup(ifLifted: "B")
        #expect(groupDrops == [CategoryGroupMove(id: "B", before: "A")])

        controller.touch(id: "y", viewportY: 135) { original }
        controller.touchGroup(id: "A", viewportY: 22) { original }
        controller.step(-1, of: "y", groups: original)
        controller.stepGroup(-1, of: "B", groups: original)
        #expect(!controller.isDragging)
        #expect(controller.groupOrder == ["B", "A"])
        #expect(drops.isEmpty)
        #expect(groupDrops.count == 1)

        controller.clearPreview()
        controller.stepGroup(-1, of: "A", groups: original.reversed())
        #expect(groupDrops.last == CategoryGroupMove(id: "A", before: "B"))
        controller.clearPreview()
    }

    @Test(arguments: [false, true])
    func voiceOverMovesShareTheSaveGuardAndRecoverAfterCompletion(movingGroup: Bool) {
        let controller = controller()
        let original = groups()
        var drops = 0
        controller.onDrop = { _ in drops += 1 }
        controller.onDropGroup = { _ in drops += 1 }

        if movingGroup {
            controller.stepGroup(-1, of: "B", groups: original)
        } else {
            controller.step(-1, of: "y", groups: original)
        }
        controller.step(-1, of: "y", groups: original)
        controller.stepGroup(-1, of: "B", groups: original)
        controller.touch(id: "y", viewportY: 135) { original }
        #expect(drops == 1)
        #expect(!controller.isDragging)

        // Completion clears the guard for both successful and failed writes.
        controller.clearPreview()
        controller.step(-1, of: "y", groups: original)
        #expect(drops == 2)
        controller.clearPreview()
    }

    @Test func voiceOverDoesNotInterruptADragAndANoOpDropDoesNotBlockMoves() {
        let controller = controller()
        let original = groups()
        var drops: [CategoryMove] = []
        controller.onDrop = { drops.append($0) }
        controller.touch(id: "y", viewportY: 135) { original }
        controller.step(-1, of: "y", groups: original)
        #expect(drops.isEmpty)

        controller.rowFrames.removeValue(forKey: "y")
        controller.finish(ifLifted: "y")
        controller.step(-1, of: "y", groups: original)
        #expect(drops == [CategoryMove(id: "y", groupId: "A", before: "x")])
        controller.clearPreview()
    }
}
