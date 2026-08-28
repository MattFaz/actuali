import Testing
@testable import Actuali

/// Engine cases ported from loot-core's category-template-context.test.ts and
/// goal-template.test.ts — expected values match upstream's.
struct GoalTemplateEngineTests {

    private let category = GoalTemplateCategory(id: "test", name: "Test Category", isIncome: false)

    private func makeContext(
        _ templates: [GoalTemplate],
        month: String = "2024-01",
        budgeted: Int = 0,
        sheet: GoalTemplateSheet = GoalTemplateSheet(),
        schedules: [GoalScheduleInfo] = [],
        allCategories: [GoalTemplateCategory] = []
    ) throws -> GoalTemplateContext {
        try GoalTemplateContext(
            templates: templates, category: category, month: month, budgeted: budgeted,
            sheet: sheet, schedules: schedules, allCategories: allCategories,
            currentMonth: month)
    }

    private func parse(_ line: String) throws -> GoalTemplate {
        try GoalTemplateParser.parse(line)
    }

    // MARK: - Periodic (January 2024 has 5 Mondays)

    @Test func periodicWeekly() throws {
        let context = try makeContext([try parse("#template-1 100 repeat every week starting 2024-01-01")])
        #expect(try context.runTemplatesForPriority(1, budgetAvail: 1_000_000, availStart: 1_000_000) == 50000)
    }

    @Test func periodicEveryTwoWeeks() throws {
        let context = try makeContext([try parse("#template-1 100 repeat every 2 weeks starting 2024-01-01")])
        #expect(try context.runTemplatesForPriority(1, budgetAvail: 1_000_000, availStart: 1_000_000) == 30000)
    }

    @Test func periodicWeeksSpanningMonths() throws {
        let context = try makeContext([try parse("#template-1 100 repeat every 7 weeks starting 2023-12-04")])
        #expect(try context.runTemplatesForPriority(1, budgetAvail: 1_000_000, availStart: 1_000_000) == 10000)
    }

    @Test func periodicDays() throws {
        // 1st, 11th, 21st, 31st
        let context = try makeContext([try parse("#template-1 100 repeat every 10 days starting 2024-01-01")])
        #expect(try context.runTemplatesForPriority(1, budgetAvail: 1_000_000, availStart: 1_000_000) == 40000)
    }

    @Test func periodicYears() throws {
        let context = try makeContext([try parse("#template-1 100 repeat every year starting 2023-01-01")])
        #expect(try context.runTemplatesForPriority(1, budgetAvail: 1_000_000, availStart: 1_000_000) == 10000)
    }

    @Test func periodicMonths() throws {
        let context = try makeContext([try parse("#template-1 100 repeat every 2 months starting 2023-11-01")])
        #expect(try context.runTemplatesForPriority(1, budgetAvail: 1_000_000, availStart: 1_000_000) == 10000)
    }

    // MARK: - Spend

    @Test func spendCountsPriorMonths() throws {
        var sheet = GoalTemplateSheet()
        sheet.spent[.init(202311, "test")] = -10000
        sheet.leftover[.init(202311, "test")] = 20000
        sheet.budgeted[.init(202312, "test")] = 10000
        let context = try makeContext(
            [try parse("#template-1 1000 by 2024-01 spend from 2023-11")], sheet: sheet)
        #expect(try context.runTemplatesForPriority(1, budgetAvail: 1_000_000, availStart: 1_000_000) == 60000)
    }

    @Test func spendRepeats() throws {
        var template = try parse("#template-1 1000 by 2023-12 spend from 2023-11")
        template.repeatCount = 3
        let context = try makeContext([template])
        #expect(try context.runTemplatesForPriority(1, budgetAvail: 1_000_000, availStart: 1_000_000) == 33333)
    }

    // MARK: - By

    @Test func byMultipleTargets() throws {
        let context = try makeContext([
            try parse("#template-1 1000 by 2024-03"),
            try parse("#template-1 2000 by 2024-06"),
        ])
        #expect(try context.runTemplatesForPriority(1, budgetAvail: 1_000_000, availStart: 1_000_000) == 66667)
    }

    @Test func byRepeatingTargets() throws {
        let context = try makeContext([
            try parse("#template-1 1000 by 2023-03 repeat every 12 months"),
            try parse("#template-1 2000 by 2023-06 repeat every 12 months"),
        ])
        #expect(try context.runTemplatesForPriority(1, budgetAvail: 1_000_000, availStart: 1_000_000) == 83333)
    }

    @Test func byWithExistingBalance() throws {
        var sheet = GoalTemplateSheet()
        sheet.leftover[.init(202312, "test")] = 500
        let context = try makeContext([
            try parse("#template-1 1000 by 2024-03"),
            try parse("#template-1 2000 by 2024-06"),
        ], sheet: sheet)
        #expect(try context.runTemplatesForPriority(1, budgetAvail: 1_000_000, availStart: 1_000_000) == 66500)
    }

    @Test func pastByWithoutRepeatErrors() throws {
        #expect(throws: (any Error).self) {
            try makeContext([try parse("#template-1 1000 by 2023-12")])
        }
    }

    // MARK: - Priorities and funds

    @Test func clampsAtAvailableFunds() throws {
        let context = try makeContext([
            try parse("#template-1 100"),
            try parse("#template-1 200"),
        ])
        #expect(try context.runTemplatesForPriority(1, budgetAvail: 150, availStart: 150) == 150)
    }

    @Test func priorityZeroMayOverbudget() throws {
        // Priority 0 has no overspend clamp, matching upstream.
        let context = try makeContext([try parse("#template 100")])
        #expect(try context.runTemplatesForPriority(0, budgetAvail: 50, availStart: 50) == 10000)
    }

    // MARK: - Limits

    @Test func limitCapsBudget() throws {
        var sheet = GoalTemplateSheet()
        sheet.leftover[.init(202312, "test")] = 9000
        let context = try makeContext([try parse("#template-1 100 up to 150")], sheet: sheet)
        #expect(try context.runTemplatesForPriority(1, budgetAvail: 10000, availStart: 10000) == 6000)
    }

    @Test func limitHoldKeepsExcess() throws {
        var sheet = GoalTemplateSheet()
        sheet.leftover[.init(202312, "test")] = 30000
        let context = try makeContext([try parse("#template-1 100 up to 200 hold")], sheet: sheet)
        #expect(context.limitExcess == 0)
    }

    @Test func limitReleasesExcess() throws {
        var sheet = GoalTemplateSheet()
        sheet.leftover[.init(202312, "test")] = 30000
        let context = try makeContext([try parse("#template-1 100 up to 200")], sheet: sheet)
        #expect(context.limitExcess == 10000)
    }

    @Test func onlyOneLimitAllowed() throws {
        #expect(throws: (any Error).self) {
            try makeContext([
                try parse("#template-1 100 up to 150"),
                try parse("#template up to 200"),
            ])
        }
    }

    // MARK: - Remainder

    @Test func remainderDistributesByWeight() throws {
        let context = try makeContext([try parse("#template remainder 2")])
        #expect(context.runRemainder(budgetAvail: 100, perWeight: 50) == 100)
    }

    @Test func remainderTakesLastCent() throws {
        let context = try makeContext([try parse("#template remainder")])
        #expect(context.runRemainder(budgetAvail: 101, perWeight: 100) == 101)
    }

    @Test func remainderWontOverbudget() throws {
        let context = try makeContext([try parse("#template remainder")])
        #expect(context.runRemainder(budgetAvail: 99, perWeight: 100) == 99)
    }

    @Test func remainderLoopTerminatesOnZeroShares() throws {
        let contexts = try (0..<5).map { _ in
            try makeContext([try parse("#template remainder")])
        }
        #expect(GoalTemplateEngine.distributeRemainder(contexts: contexts, availBudget: 2) == 2)
    }

    // MARK: - Goals

    @Test func goalDirectiveSetsLongGoal() throws {
        let context = try makeContext([
            try parse("#template-1 100"),
            try parse("#goal 1000"),
        ])
        _ = try context.runTemplatesForPriority(1, budgetAvail: 1_000_000, availStart: 1_000_000)
        let values = context.getValues()
        #expect(values.budgeted == 10000)
        #expect(values.goal == 100_000)
        #expect(values.longGoal == true)
    }

    @Test func goalOnlyKeepsExistingBudget() throws {
        let context = try makeContext([try parse("#goal 1000")], budgeted: 12345)
        let values = context.getValues()
        #expect(values.budgeted == 12345)
        #expect(values.goal == 100_000)
        #expect(values.longGoal == true)
    }

    @Test func templateGoalIsFullRequestedAmount() throws {
        // Underfunded template: goal records the full requested amount even
        // though the budget clamps to what's available.
        let context = try makeContext([try parse("#template-1 300")])
        let budgeted = try context.runTemplatesForPriority(1, budgetAvail: 150, availStart: 150)
        #expect(budgeted == 150)
        let values = context.getValues()
        #expect(values.budgeted == 150)
        #expect(values.goal == 30000)
        #expect(values.longGoal == nil)
    }

    // MARK: - Percentage

    @Test func percentageOfAllIncome() throws {
        var sheet = GoalTemplateSheet()
        sheet.totalIncome[202401] = 300_000
        let context = try makeContext([try parse("#template-1 10% of all income")], sheet: sheet)
        #expect(try context.runTemplatesForPriority(1, budgetAvail: 1_000_000, availStart: 1_000_000) == 30000)
    }

    @Test func percentageOfNamedCategoryPreviousMonth() throws {
        var sheet = GoalTemplateSheet()
        sheet.spent[.init(202312, "salary")] = 500_000
        let salary = GoalTemplateCategory(id: "salary", name: "Salary", isIncome: true)
        let context = try makeContext(
            [try parse("#template-1 10% of previous Salary")],
            sheet: sheet, allCategories: [salary, category])
        #expect(try context.runTemplatesForPriority(1, budgetAvail: 1_000_000, availStart: 1_000_000) == 50000)
    }

    @Test func percentageOfUnknownCategoryErrors() throws {
        #expect(throws: (any Error).self) {
            try makeContext([try parse("#template-1 10% of Nothing")])
        }
    }

    // MARK: - Average / Copy

    @Test func averageOfThreeMonths() throws {
        var sheet = GoalTemplateSheet()
        sheet.spent[.init(202312, "test")] = -10000
        sheet.spent[.init(202311, "test")] = -20000
        sheet.spent[.init(202310, "test")] = -30000
        sheet.firstActivityMonth["test"] = 202310
        let context = try makeContext([try parse("#template-1 average 3 months")], sheet: sheet)
        #expect(try context.runTemplatesForPriority(1, budgetAvail: 1_000_000, availStart: 1_000_000) == 20000)
    }

    @Test func averageStopsAtFirstActivity() throws {
        var sheet = GoalTemplateSheet()
        sheet.spent[.init(202312, "test")] = -30000
        sheet.firstActivityMonth["test"] = 202312
        let context = try makeContext([try parse("#template-1 average 6 months")], sheet: sheet)
        #expect(try context.runTemplatesForPriority(1, budgetAvail: 1_000_000, availStart: 1_000_000) == 30000)
    }

    @Test func copyFromMonthsAgo() throws {
        var sheet = GoalTemplateSheet()
        sheet.budgeted[.init(202310, "test")] = 42000
        let context = try makeContext([try parse("#template-1 copy from 3 months ago")], sheet: sheet)
        #expect(try context.runTemplatesForPriority(1, budgetAvail: 1_000_000, availStart: 1_000_000) == 42000)
    }

    // MARK: - hideFraction

    @Test func hideFractionRoundsToWholeUnits() throws {
        var sheet = GoalTemplateSheet()
        sheet.hideFraction = true
        let context = try makeContext([try parse("#template-1 100.5")], sheet: sheet)
        #expect(try context.runTemplatesForPriority(1, budgetAvail: 1_000_000, availStart: 1_000_000) == 10100)
    }

    // MARK: - Schedules

    private func monthlySchedule(
        id: String = "sched-rent", name: String = "Rent",
        amount: Int = -50000, start: String = "2024-01-15"
    ) -> GoalScheduleInfo {
        GoalScheduleInfo(
            id: id, name: name, completed: false,
            amount: .fixed(amount),
            dateCondition: .recurring(RecurConfig(
                frequency: .monthly, start: DayDate(iso: start)!)))
    }

    @Test func monthlyScheduleBudgetsThisMonthsTarget() throws {
        let context = try makeContext(
            [try parse("#template-1 schedule Rent")], schedules: [monthlySchedule()])
        #expect(try context.runTemplatesForPriority(1, budgetAvail: 1_000_000, availStart: 1_000_000) == 50000)
    }

    @Test func yearlyScheduleSinksMonthly() throws {
        let insurance = GoalScheduleInfo(
            id: "sched-ins", name: "Insurance", completed: false,
            amount: .fixed(-120_000),
            dateCondition: .recurring(RecurConfig(
                frequency: .yearly, start: DayDate(iso: "2024-06-15")!)))
        let context = try makeContext(
            [try parse("#template-1 schedule Insurance")], schedules: [insurance])
        // Due in 5 months: 120000 / 6 per month.
        #expect(try context.runTemplatesForPriority(1, budgetAvail: 1_000_000, availStart: 1_000_000) == 20000)
    }

    @Test func scheduleAdjustmentIncreasesTarget() throws {
        let context = try makeContext(
            [try parse("#template-1 schedule Rent [increase 10%]")],
            schedules: [monthlySchedule()])
        #expect(try context.runTemplatesForPriority(1, budgetAvail: 1_000_000, availStart: 1_000_000) == 55000)
    }

    @Test func missingScheduleErrors() throws {
        #expect(throws: (any Error).self) {
            try makeContext([try parse("#template-1 schedule Ghost")])
        }
    }

    @Test func mixedSchedulePrioritiesError() throws {
        #expect(throws: (any Error).self) {
            try makeContext([
                try parse("#template-1 schedule Rent"),
                try parse("#template-2 500 by 2024-06"),
            ], schedules: [monthlySchedule()])
        }
    }

    // MARK: - Full engine runs

    private func runEngine(
        month: String = "2024-01",
        force: Bool = false,
        templates: [String: [GoalTemplate]],
        categories: [GoalTemplateCategory]? = nil,
        sheet: GoalTemplateSheet = GoalTemplateSheet(),
        schedules: [GoalScheduleInfo] = []
    ) -> GoalTemplateEngine.RunResult {
        let processCategories = categories ?? [category]
        return GoalTemplateEngine.run(
            month: month, force: force,
            categoryTemplates: templates,
            categories: processCategories,
            allCategories: processCategories,
            schedules: schedules,
            sheet: sheet,
            currentMonth: month)
    }

    @Test func appliesTemplatesAndWritesGoals() throws {
        var sheet = GoalTemplateSheet()
        sheet.availableStart = 100_000
        let result = runEngine(
            templates: ["test": [try parse("#template-1 100")]], sheet: sheet)
        #expect(result == .applied(
            count: 1,
            budgets: [.init(category: "test", amount: 10000)],
            goals: [.init(category: "test", goal: 10000, longGoal: false)]))
    }

    @Test func lowerPriorityClampsWhenFundsRunOut() throws {
        var sheet = GoalTemplateSheet()
        sheet.availableStart = 40000
        let first = GoalTemplateCategory(id: "a", name: "A", isIncome: false)
        let second = GoalTemplateCategory(id: "b", name: "B", isIncome: false)
        let result = runEngine(
            templates: [
                "a": [try parse("#template-1 300")],
                "b": [try parse("#template-2 300")],
            ],
            categories: [first, second],
            sheet: sheet)
        guard case .applied(let count, let budgets, _) = result else {
            Issue.record("expected applied, got \(result)")
            return
        }
        #expect(count == 2)
        #expect(budgets.first { $0.category == "a" }?.amount == 30000)
        #expect(budgets.first { $0.category == "b" }?.amount == 10000)
    }

    @Test func skipsAlreadyBudgetedWithoutForce() throws {
        var sheet = GoalTemplateSheet()
        sheet.availableStart = 100_000
        sheet.budgeted[.init(202401, "test")] = 5000
        let result = runEngine(templates: ["test": [try parse("#template-1 100")]], sheet: sheet)
        #expect(result == .upToDate(goalResets: []))

        let forced = runEngine(
            force: true, templates: ["test": [try parse("#template-1 100")]], sheet: sheet)
        guard case .applied(let count, let budgets, _) = forced else {
            Issue.record("expected applied, got \(forced)")
            return
        }
        #expect(count == 1)
        #expect(budgets == [.init(category: "test", amount: 10000)])
    }

    @Test func orphanedGoalsAreReset() throws {
        var sheet = GoalTemplateSheet()
        sheet.goalRows.insert(.init(202401, "test"))
        sheet.goals[.init(202401, "test")] = 5000
        let result = runEngine(templates: [:], sheet: sheet)
        #expect(result == .upToDate(goalResets: [
            .init(category: "test", goal: nil, longGoal: false),
        ]))
    }

    @Test func templateErrorsSurfaceCategoryName() throws {
        let result = runEngine(templates: ["test": [try parse("#template-1 1000 by 2023-06")]])
        guard case .errors(let errors) = result else {
            Issue.record("expected errors, got \(result)")
            return
        }
        #expect(errors.count == 1)
        #expect(errors[0].hasPrefix("Test Category:"))
        #expect(errors[0].contains("Target month has passed"))
    }

    @Test func remainderSpreadsLeftoverPoolByWeight() throws {
        var sheet = GoalTemplateSheet()
        sheet.availableStart = 90000
        let first = GoalTemplateCategory(id: "a", name: "A", isIncome: false)
        let second = GoalTemplateCategory(id: "b", name: "B", isIncome: false)
        let result = runEngine(
            templates: [
                "a": [try parse("#template remainder 2")],
                "b": [try parse("#template remainder")],
            ],
            categories: [first, second],
            sheet: sheet)
        guard case .applied(_, let budgets, let goals) = result else {
            Issue.record("expected applied, got \(result)")
            return
        }
        #expect(budgets.first { $0.category == "a" }?.amount == 60000)
        #expect(budgets.first { $0.category == "b" }?.amount == 30000)
        // Remainder-only categories carry no goal.
        #expect(goals.allSatisfy { $0.goal == nil })
    }

    @Test func trackingBudgetFundsFromTotalSaved() throws {
        var sheet = GoalTemplateSheet()
        sheet.isTracking = true
        sheet.availableStart = 25000
        let result = runEngine(
            templates: ["test": [try parse("#template-1 300")]], sheet: sheet)
        guard case .applied(_, let budgets, _) = result else {
            Issue.record("expected applied, got \(result)")
            return
        }
        // 300 requested, only 250 in total-saved: clamped.
        #expect(budgets == [.init(category: "test", amount: 25000)])
    }

    @Test func limitExcessReturnsToPool() throws {
        // Category over its held... non-hold limit releases the excess into
        // the pool, where a remainder template can pick it up.
        var sheet = GoalTemplateSheet()
        sheet.availableStart = 0
        sheet.leftover[.init(202312, "a")] = 30000
        let first = GoalTemplateCategory(id: "a", name: "A", isIncome: false)
        let second = GoalTemplateCategory(id: "b", name: "B", isIncome: false)
        let result = runEngine(
            templates: [
                "a": [try parse("#template-1 100 up to 200")],
                "b": [try parse("#template remainder")],
            ],
            categories: [first, second],
            sheet: sheet)
        guard case .applied(_, let budgets, _) = result else {
            Issue.record("expected applied, got \(result)")
            return
        }
        // a: clamped to -(excess) = -10000; b: receives the released 10000.
        #expect(budgets.first { $0.category == "a" }?.amount == -10000)
        #expect(budgets.first { $0.category == "b" }?.amount == 10000)
    }

    // MARK: - Malformed input (the grammar is digits-only, so these parse)

    @Test func periodicZeroPeriodBudgetsNothing() throws {
        var template = try parse("#template-1 100 repeat every 2 weeks starting 2024-01-01")
        template.period = .init(period: .week, amount: 0)
        let context = try makeContext([template])
        #expect(try context.runTemplatesForPriority(1, budgetAvail: 1_000_000, availStart: 1_000_000) == 0)
    }

    @Test func periodicInvalidStartDateBudgetsNothing() throws {
        let context = try makeContext([try parse("#template-1 100 repeat every week starting 0000-00-00")])
        #expect(try context.runTemplatesForPriority(1, budgetAvail: 1_000_000, availStart: 1_000_000) == 0)
    }

    @Test func weeklyLimitInvalidStartDateIsAnError() throws {
        #expect(throws: GoalTemplateError.self) {
            _ = try makeContext([try parse("#template 100 up to 150 per week starting 2023-13-01")])
        }
    }
}
