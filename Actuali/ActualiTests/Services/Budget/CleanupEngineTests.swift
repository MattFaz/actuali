import Testing
@testable import Actuali

struct CleanupEngineTests {
    @Test func appliesPoolsThenGlobalRulesAndSinkWeights() {
        let month = "2026-08"
        let categories: [CleanupEngine.Category] = [
            .init(id: "pool-source", name: "Pool Source", cleanup: [.source(groupId: "pool")]),
            .init(id: "pool-overspent", name: "Pool Overspent", cleanup: [.overspend(groupId: "pool")]),
            .init(id: "pool-sink", name: "Pool Sink", cleanup: [.sink(groupId: "pool")]),
            .init(id: "global-source", name: "Global Source", cleanup: [.source()]),
            .init(id: "global-overspent", name: "Global Overspent", cleanup: []),
            .init(id: "global-sink-1", name: "Global Sink 1", cleanup: [.sink(weight: 1)]),
            .init(id: "global-sink-2", name: "Global Sink 2", cleanup: [.sink(weight: 3)]),
        ]
        var sheet = GoalTemplateSheet()
        sheet.budgeted[.init(202608, "pool-source")] = 1_000
        sheet.leftover[.init(202608, "pool-source")] = 1_000
        sheet.leftover[.init(202608, "pool-overspent")] = -600
        sheet.budgeted[.init(202608, "global-source")] = 300
        sheet.leftover[.init(202608, "global-source")] = 300
        sheet.leftover[.init(202608, "global-overspent")] = -100

        let result = CleanupEngine.run(
            month: month,
            categories: categories,
            groupNames: ["pool": "Utilities"],
            sheet: sheet
        )

        #expect(result.budgets == [
            .init(category: "pool-source", amount: 0),
            .init(category: "pool-overspent", amount: 600),
            .init(category: "pool-sink", amount: 400),
            .init(category: "global-source", amount: 0),
            .init(category: "global-overspent", amount: 100),
            .init(category: "global-sink-1", amount: 50),
            .init(category: "global-sink-2", amount: 150),
        ])
        #expect(result.goals == [.init(category: "global-source", goal: 0, longGoal: false)])
        #expect(result.notification == .applied(sourceCount: 1, sinkCount: 2))
    }

    @Test func poolRoundingDoesNotAllocateMoreThanAvailable() {
        let categories: [CleanupEngine.Category] = [
            .init(id: "source", name: "Source", cleanup: [.source(groupId: "pool")]),
            .init(id: "sink-1", name: "Sink 1", cleanup: [.sink(groupId: "pool")]),
            .init(id: "sink-2", name: "Sink 2", cleanup: [.sink(groupId: "pool")]),
        ]
        var sheet = GoalTemplateSheet()
        sheet.budgeted[.init(202608, "source")] = 1
        sheet.leftover[.init(202608, "source")] = 1

        let result = CleanupEngine.run(
            month: "2026-08", categories: categories, groupNames: [:], sheet: sheet)

        #expect(result.budgets.filter { $0.category.hasPrefix("sink") }
            .map(\.amount).reduce(0, +) == 1)
        #expect(result.notification == .applied(sourceCount: 0, sinkCount: 0))
    }

    @Test func negativeAvailableFundsDoNotWorsenOverspending() {
        let categories: [CleanupEngine.Category] = [
            .init(id: "overspent", name: "Overspent", cleanup: []),
            .init(id: "sink", name: "Sink", cleanup: [.sink()]),
        ]
        var sheet = GoalTemplateSheet()
        sheet.availableStart = -100
        sheet.leftover[.init(202608, "overspent")] = -50

        let result = CleanupEngine.run(
            month: "2026-08", categories: categories, groupNames: [:], sheet: sheet)

        #expect(result.budgets.isEmpty)
        #expect(result.notification == .warning([.noGlobalFunds]))
    }
}
