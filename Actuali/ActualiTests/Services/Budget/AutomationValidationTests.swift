import Testing
@testable import Actuali

struct AutomationValidationTests {

    private let currentMonth = "2024-01"
    private let sources: Set<String> = ["all income", "available funds", "cat-salary", "salary"]

    private func parse(_ line: String) throws -> GoalTemplate {
        try GoalTemplateParser.parse(line)
    }

    private func validate(
        _ entry: AutomationEntry,
        all: [GoalTemplate]? = nil,
        schedules: [GoalScheduleInfo] = []
    ) -> AutomationError? {
        AutomationValidation.validate(
            entry: entry,
            allTemplates: all ?? [entry.template],
            schedules: schedules,
            currentMonth: currentMonth,
            validPercentageSources: sources)
    }

    @Test func scheduleMustExistAndBeActive() throws {
        let entry = AutomationEntry(
            template: try parse("#template schedule Rent"), displayType: .schedule)
        #expect(validate(entry) == .scheduleNotFound(name: "Rent"))

        let active = GoalScheduleInfo(
            id: "s1", name: "Rent", completed: false, amount: nil, dateCondition: nil)
        #expect(validate(entry, schedules: [active]) == nil)

        let completed = GoalScheduleInfo(
            id: "s1", name: "Rent", completed: true, amount: nil, dateCondition: nil)
        #expect(validate(entry, schedules: [completed]) == .scheduleNotFound(name: "Rent"))

        var empty = BudgetAutomations.defaultTemplate(for: .schedule)
        empty.name = ""
        #expect(validate(AutomationEntry(template: empty, displayType: .schedule))
            == .scheduleNotFound(name: ""))
    }

    @Test func refillNeedsALimit() throws {
        let refill = AutomationEntry(
            template: BudgetAutomations.defaultTemplate(for: .refill), displayType: .refill)
        #expect(validate(refill) == .refillNoCap)
        let limit = BudgetAutomations.defaultTemplate(for: .limit)
        #expect(validate(refill, all: [refill.template, limit]) == nil)
    }

    @Test func limitNeedsAContributor() throws {
        let limit = AutomationEntry(
            template: BudgetAutomations.defaultTemplate(for: .limit), displayType: .limit)
        #expect(validate(limit) == .limitNoContributor)
        let fixed = BudgetAutomations.defaultTemplate(for: .fixed)
        #expect(validate(limit, all: [limit.template, fixed]) == nil)
    }

    @Test func percentageChecks() throws {
        var template = BudgetAutomations.defaultTemplate(for: .percentage)
        template.category = nil
        #expect(validate(AutomationEntry(template: template, displayType: .percentage))
            == .percentageNoSource)

        template.category = "all income"
        template.percent = 150
        #expect(validate(AutomationEntry(template: template, displayType: .percentage))
            == .percentageOutOfRange(percent: 150))

        template.percent = 20
        template.category = "Ghost"
        #expect(validate(AutomationEntry(template: template, displayType: .percentage))
            == .percentageSourceNotFound(source: "Ghost"))

        template.category = "Salary"
        #expect(validate(AutomationEntry(template: template, displayType: .percentage)) == nil)
    }

    @Test func byAndSpendChecks() throws {
        var by = try parse("#template 500 by 2023-06")
        #expect(validate(AutomationEntry(template: by, displayType: .by))
            == .byTargetPast(month: "2023-06"))

        // A repeating past anchor rolls forward and is fine.
        by.annual = true
        #expect(validate(AutomationEntry(template: by, displayType: .by)) == nil)

        var spend = try parse("#template 500 by 2024-06 spend from 2024-03")
        #expect(validate(AutomationEntry(template: spend, displayType: .by)) == nil)
        spend.from = "2024-09"
        #expect(validate(AutomationEntry(template: spend, displayType: .by))
            == .spendFromAfterTarget)

        var noMonth = BudgetAutomations.defaultTemplate(for: .by)
        noMonth.month = nil
        #expect(validate(AutomationEntry(template: noMonth, displayType: .by)) == .byNoMonth)
    }

    @Test func adjustmentBounds() throws {
        var schedule = try parse("#template schedule Rent")
        schedule.adjustment = 1500
        schedule.adjustmentType = .percent
        let active = GoalScheduleInfo(
            id: "s1", name: "Rent", completed: false, amount: nil, dateCondition: nil)
        #expect(validate(
            AutomationEntry(template: schedule, displayType: .schedule),
            schedules: [active]) == .adjustmentOutOfRange)
    }

    @Test func percentageAllocationConflict() throws {
        let templates = [
            try parse("#template 60% of all income"),
            try parse("#template 50% of all income"),
        ]
        #expect(AutomationValidation.percentageAllocationConflict(templates)
            == .percentOver100(total: 110))
        // Different sources don't sum together.
        let split = [
            try parse("#template 60% of all income"),
            try parse("#template 50% of Salary"),
        ]
        #expect(AutomationValidation.percentageAllocationConflict(split) == nil)
    }

    @Test func schedulePriorityConflict() throws {
        let mismatched = [
            try parse("#template-1 schedule Rent"),
            try parse("#template-2 500 by 2025-12"),
        ]
        #expect(AutomationValidation.schedulePriorityConflict(mismatched)
            == .schedulePriorityMismatch)
        let matched = [
            try parse("#template-1 schedule Rent"),
            try parse("#template-1 500 by 2025-12"),
        ]
        #expect(AutomationValidation.schedulePriorityConflict(matched) == nil)
    }
}
