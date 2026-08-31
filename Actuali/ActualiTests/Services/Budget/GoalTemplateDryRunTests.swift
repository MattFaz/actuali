import Testing
@testable import Actuali

/// Dry-run projections (upstream dryRunCategoryTemplate) and the
/// per-template contribution tracking behind them.
struct GoalTemplateDryRunTests {

    private let category = GoalTemplateCategory(id: "test", name: "Test Category", isIncome: false)

    private func parse(_ line: String) throws -> GoalTemplate {
        try GoalTemplateParser.parse(line)
    }

    private func dryRun(
        _ templates: [GoalTemplate],
        sheet: GoalTemplateSheet = GoalTemplateSheet(),
        schedules: [GoalScheduleInfo] = [],
        month: String = "2024-01"
    ) -> (budgeted: Int, perTemplate: [Int]) {
        GoalTemplateEngine.dryRun(
            month: month,
            category: category,
            templates: templates,
            allCategories: [category],
            schedules: schedules,
            sheet: sheet,
            currentMonth: month)
    }

    @Test func showsFullDemandEvenWithoutFunds() throws {
        // availableStart is 0, but the dry run skips the clamp so the
        // projection shows the template's intended amount.
        let result = dryRun([try parse("#template-1 300")])
        #expect(result.budgeted == 30000)
        #expect(result.perTemplate == [30000])
    }

    @Test func splitsByBatchAcrossSiblings() throws {
        let result = dryRun([
            try parse("#template-1 1000 by 2024-03"),
            try parse("#template-1 2000 by 2024-06"),
        ])
        // Total matches the engine's runBy (66667); the batch splits by each
        // template's per-month need (equal here), last takes the residual.
        #expect(result.budgeted == 66667)
        #expect(result.perTemplate == [33334, 33333])
        #expect(result.perTemplate.reduce(0, +) == result.budgeted)
    }

    @Test func splitsScheduleBatchByMonthlyContribution() throws {
        func monthly(_ id: String, _ name: String, _ amount: Int) -> GoalScheduleInfo {
            GoalScheduleInfo(
                id: id, name: name, completed: false, amount: .fixed(amount),
                dateCondition: .recurring(RecurConfig(
                    frequency: .monthly, start: DayDate(iso: "2024-01-15")!)))
        }
        let result = dryRun(
            [
                try parse("#template-1 schedule Rent"),
                try parse("#template-1 schedule Water"),
            ],
            schedules: [
                monthly("s1", "Rent", -50000),
                monthly("s2", "Water", -25000),
            ])
        #expect(result.budgeted == 75000)
        #expect(result.perTemplate == [50000, 25000])
    }

    @Test func splitsRemainderByWeight() throws {
        var sheet = GoalTemplateSheet()
        sheet.availableStart = 90000
        let result = dryRun([
            try parse("#template remainder 2"),
            try parse("#template remainder"),
        ], sheet: sheet)
        #expect(result.budgeted == 90000)
        #expect(result.perTemplate == [60000, 30000])
    }

    @Test func goalTemplateContributesNothing() throws {
        let result = dryRun([
            try parse("#template-1 100"),
            try parse("#goal 1000"),
        ])
        #expect(result.budgeted == 10000)
        #expect(result.perTemplate == [10000, 0])
    }

    @Test func validationErrorsReturnZeros() throws {
        let result = dryRun([try parse("#template-1 schedule Ghost")])
        #expect(result.budgeted == 0)
        #expect(result.perTemplate == [0])
    }

    @Test func clampedRunScalesContributions() throws {
        // Through the normal (clamped) path: two templates at priority 1 with
        // only 150 cents available scale down proportionally, and the shares
        // sum to the budgeted amount exactly.
        let context = try GoalTemplateContext(
            templates: [try parse("#template-1 100"), try parse("#template-1 200")],
            category: category,
            month: "2024-01",
            budgeted: 0,
            sheet: GoalTemplateSheet(),
            schedules: [],
            allCategories: [],
            currentMonth: "2024-01")
        let budgeted = try context.runTemplatesForPriority(1, budgetAvail: 150, availStart: 150)
        #expect(budgeted == 150)
        let values = context.getValues()
        #expect(values.perTemplate.reduce(0, +) == 150)
        #expect(values.perTemplate == [50, 100])
    }

    @Test func limitCapScalesContributions() throws {
        var sheet = GoalTemplateSheet()
        sheet.leftover[.init(202312, "test")] = 9000
        let context = try GoalTemplateContext(
            templates: [try parse("#template-1 100 up to 150")],
            category: category,
            month: "2024-01",
            budgeted: 0,
            sheet: sheet,
            schedules: [],
            allCategories: [],
            currentMonth: "2024-01")
        let budgeted = try context.runTemplatesForPriority(
            1, budgetAvail: 100_000, availStart: 100_000)
        #expect(budgeted == 6000)
        #expect(context.getValues().perTemplate == [6000])
    }
}
