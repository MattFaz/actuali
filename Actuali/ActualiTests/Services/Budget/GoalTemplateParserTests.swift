import Testing
@testable import Actuali

/// Parser cases mirror loot-core's goal-template.pegjs grammar and the
/// examples in Actual's goal templates documentation.
struct GoalTemplateParserTests {

    private func parse(_ line: String) throws -> GoalTemplate {
        try GoalTemplateParser.parse(line)
    }

    // MARK: - Simple

    @Test func parsesSimpleAmount() throws {
        let template = try parse("#template 50")
        #expect(template.type == .simple)
        #expect(template.directive == .template)
        #expect(template.monthly == 50)
        #expect(template.priority == 0)
        #expect(template.limit == nil)
    }

    @Test func parsesPriority() throws {
        #expect(try parse("#template-5 50").priority == 5)
        #expect(try parse("#template-0 50").priority == 0)
    }

    @Test func parsesDecimalAndNegativeAmounts() throws {
        #expect(try parse("#template 50.5").monthly == 50.5)
        #expect(try parse("#template -25").monthly == -25)
        #expect(try parse("#template $75").monthly == 75)
    }

    @Test func parsesSimpleWithLimit() throws {
        let template = try parse("#template 50 up to 100")
        #expect(template.monthly == 50)
        #expect(template.limit == .init(amount: 100, hold: false, period: .monthly, start: nil))

        let hold = try parse("#template 50 up to 100 hold")
        #expect(hold.limit?.hold == true)
    }

    @Test func parsesLimitOnly() throws {
        let template = try parse("#template up to 500")
        #expect(template.type == .simple)
        #expect(template.monthly == nil)
        #expect(template.limit?.amount == 500)
    }

    @Test func parsesDailyAndWeeklyLimits() throws {
        let daily = try parse("#template up to 10 per day")
        #expect(daily.limit == .init(amount: 10, hold: false, period: .daily, start: nil))

        let weekly = try parse("#template up to 100 per week starting 2024-01-01 hold")
        #expect(weekly.limit == .init(
            amount: 100, hold: true, period: .weekly, start: "2024-01-01"))
    }

    // MARK: - Percentage

    @Test func parsesPercentage() throws {
        let template = try parse("#template 15% of All Income")
        #expect(template.type == .percentage)
        #expect(template.percent == 15)
        #expect(template.previous == false)
        #expect(template.category == "All Income")
    }

    @Test func parsesPercentageOfPrevious() throws {
        let template = try parse("#template 10.5% of previous Salary")
        #expect(template.percent == 10.5)
        #expect(template.previous == true)
        #expect(template.category == "Salary")
    }

    // MARK: - By / Spend

    @Test func parsesBy() throws {
        let template = try parse("#template 500 by 2025-12")
        #expect(template.type == .by)
        #expect(template.amount == 500)
        #expect(template.month == "2025-12")
        #expect(template.annual == nil)
    }

    @Test func parsesByWithRepeat() throws {
        let monthly = try parse("#template 500 by 2025-12 repeat every 6 months")
        #expect(monthly.annual == false)
        #expect(monthly.repeatCount == 6)

        let yearly = try parse("#template 500 by 2025-12 repeat every year")
        #expect(yearly.annual == true)
        #expect(yearly.repeatCount == nil)

        let years = try parse("#template 500 by 2025-12 repeat every 2 years")
        #expect(years.annual == true)
        #expect(years.repeatCount == 2)
    }

    @Test func parsesSpendFrom() throws {
        let template = try parse("#template 500 by 2025-12 spend from 2025-03")
        #expect(template.type == .spend)
        #expect(template.month == "2025-12")
        #expect(template.from == "2025-03")
    }

    // MARK: - Periodic

    @Test func parsesPeriodic() throws {
        let template = try parse("#template 100 repeat every week starting 2024-01-01")
        #expect(template.type == .periodic)
        #expect(template.amount == 100)
        #expect(template.period == .init(period: .week, amount: 1))
        #expect(template.starting == "2024-01-01")
    }

    @Test func parsesPeriodicVariants() throws {
        #expect(try parse("#template 10 repeat every 2 weeks starting 2024-01-01")
            .period == .init(period: .week, amount: 2))
        #expect(try parse("#template 10 repeat every 10 days starting 2024-01-01")
            .period == .init(period: .day, amount: 10))
        #expect(try parse("#template 10 repeat every day starting 2024-01-01")
            .period == .init(period: .day, amount: 1))
        #expect(try parse("#template 10 repeat every 2 months starting 2024-01-01")
            .period == .init(period: .month, amount: 2))
        #expect(try parse("#template 10 repeat every year starting 2024-01-01")
            .period == .init(period: .year, amount: 1))
    }

    @Test func parsesPeriodicWithLimit() throws {
        let template = try parse(
            "#template 10 repeat every 2 weeks starting 2024-01-04 up to 60")
        #expect(template.period == .init(period: .week, amount: 2))
        #expect(template.limit?.amount == 60)
    }

    // MARK: - Schedule

    @Test func parsesSchedule() throws {
        let template = try parse("#template schedule Rent")
        #expect(template.type == .schedule)
        #expect(template.name == "Rent")
        #expect(template.full == nil)
    }

    @Test func parsesScheduleFull() throws {
        let template = try parse("#template schedule full Car Insurance")
        #expect(template.name == "Car Insurance")
        #expect(template.full == true)
    }

    @Test func parsesScheduleAdjustments() throws {
        let increase = try parse("#template schedule Rent [increase 5%]")
        #expect(increase.name == "Rent")
        #expect(increase.adjustment == 5)
        #expect(increase.adjustmentType == .percent)

        let decrease = try parse("#template schedule Rent [decrease 10]")
        #expect(decrease.adjustment == -10)
        #expect(decrease.adjustmentType == .fixed)
    }

    // MARK: - Remainder / Average / Copy

    @Test func parsesRemainder() throws {
        let plain = try parse("#template remainder")
        #expect(plain.type == .remainder)
        #expect(plain.weight == 1)
        #expect(plain.priority == nil)

        let weighted = try parse("#template remainder 3")
        #expect(weighted.weight == 3)

        let limited = try parse("#template remainder 2 up to 300")
        #expect(limited.weight == 2)
        #expect(limited.limit?.amount == 300)
    }

    @Test func parsesAverage() throws {
        let template = try parse("#template average 6 months")
        #expect(template.type == .average)
        #expect(template.numMonths == 6)

        let short = try parse("#template average 3")
        #expect(short.numMonths == 3)

        let adjusted = try parse("#template average 4 months [increase 10%]")
        #expect(adjusted.adjustment == 10)
        #expect(adjusted.adjustmentType == .percent)
    }

    @Test func parsesCopy() throws {
        let template = try parse("#template copy from 3 months ago")
        #expect(template.type == .copy)
        #expect(template.lookBack == 3)
    }

    // MARK: - Goal

    @Test func parsesGoal() throws {
        let template = try parse("#goal 500")
        #expect(template.type == .goal)
        #expect(template.directive == .goal)
        #expect(template.amount == 500)
        #expect(template.priority == nil)
    }

    @Test func rejectsInvalidLines() {
        #expect(throws: (any Error).self) { try GoalTemplateParser.parse("#template blah") }
        #expect(throws: (any Error).self) { try GoalTemplateParser.parse("#template 500 by 12-2025") }
        #expect(throws: (any Error).self) { try GoalTemplateParser.parse("#goal") }
    }

    // MARK: - Note extraction

    @Test func extractsTemplatesFromNote() {
        let note = """
        Some regular note line

        Saving for the trip
        #template 50
        #goal 1000
        """
        let templates = GoalTemplateNotes.parseTemplates(fromNote: note)
        #expect(templates.count == 2)
        #expect(templates[0].type == .simple)
        #expect(templates[0].description == "Saving for the trip")
        #expect(templates[1].type == .goal)
        #expect(templates[1].description == nil)
    }

    @Test func extractsTemplateAfterLeadingText() {
        // Upstream slices the line at the first '#', so prefixed text still
        // parses as a template line.
        let templates = GoalTemplateNotes.parseTemplates(fromNote: "monthly food #template 400")
        #expect(templates.count == 1)
        #expect(templates[0].monthly == 400)
    }

    @Test func unparseableLineBecomesErrorTemplate() {
        let templates = GoalTemplateNotes.parseTemplates(fromNote: "#template nonsense here")
        #expect(templates.count == 1)
        #expect(templates[0].type == .error)
        #expect(templates[0].line == "#template nonsense here")
    }

    @Test func adjustmentOutOfBoundsBecomesError() {
        let templates = GoalTemplateNotes.parseTemplates(
            fromNote: "#template schedule Rent [increase 1001%]")
        #expect(templates.count == 1)
        #expect(templates[0].type == .error)
        #expect(templates[0].error?.contains("adjustment") == true)
    }

    @Test func templatePrefixIsCaseSensitive() {
        // '#Template' is not a directive upstream (startsWith is exact).
        let templates = GoalTemplateNotes.parseTemplates(fromNote: "#Template 50")
        #expect(templates.isEmpty)
    }

    // MARK: - goal_def JSON round trip

    @Test func roundTripsThroughGoalDefJSON() throws {
        let lines = [
            "#template 50 up to 100",
            "#template-2 500 by 2025-12 spend from 2025-03",
            "#template 15% of previous All Income",
            "#template schedule full Rent [increase 5%]",
            "#template remainder 3",
            "#goal 1000",
        ]
        let templates = try lines.map(parse)
        let encoded = try #require(GoalTemplate.encodeArray(templates))
        let decoded = try #require(GoalTemplate.decodeArray(fromJSON: encoded))
        #expect(decoded == templates)
    }

    @Test func decodesWebUITemplateTypes() throws {
        // Shapes the web's template-editor UI stores: refill + top-level
        // limit template, and scheduleId-addressed schedules.
        let json = """
        [{"type":"refill","directive":"template","priority":0},
         {"type":"limit","directive":"template","priority":null,"amount":150,"hold":true,"period":"monthly"},
         {"type":"schedule","directive":"template","priority":1,"scheduleId":"sched-1"}]
        """
        let decoded = try #require(GoalTemplate.decodeArray(fromJSON: json))
        #expect(decoded.count == 3)
        #expect(decoded[0].type == .refill)
        #expect(decoded[1].type == .limit)
        #expect(decoded[1].limit == .init(amount: 150, hold: true, period: .monthly, start: nil))
        #expect(decoded[2].scheduleId == "sched-1")
    }

    @Test func unknownTypeDecodesAsError() throws {
        let decoded = try #require(GoalTemplate.decodeArray(
            fromJSON: #"[{"type":"quantum","directive":"template","priority":0}]"#))
        #expect(decoded.count == 1)
        #expect(decoded[0].type == .error)
    }
}

struct BudgetMonthMathTests {

    @Test func monthArithmetic() {
        #expect(BudgetMonthMath.addMonths("2024-11", 3) == "2025-02")
        #expect(BudgetMonthMath.subMonths("2024-01", 2) == "2023-11")
        // Day strings collapse to months, as upstream's addMonths does.
        #expect(BudgetMonthMath.addMonths("2024-01-15", 1) == "2024-02")
        #expect(BudgetMonthMath.differenceInCalendarMonths("2024-06", "2024-01-20") == 5)
        #expect(BudgetMonthMath.differenceInCalendarMonths("2023-11", "2024-01") == -2)
    }

    @Test func dayArithmetic() {
        #expect(BudgetMonthMath.addDays("2024-01-31", 1) == "2024-02-01")
        #expect(BudgetMonthMath.addWeeks("2024-01-01", 2) == "2024-01-15")
        #expect(BudgetMonthMath.daysInMonth("2024-02") == 29)
        #expect(BudgetMonthMath.firstDayOfMonth("2024-02") == "2024-02-01")
    }

    @Test func jsRoundingSemantics() {
        // JS Math.round: half goes toward +∞.
        #expect(BudgetMonthMath.jsRound(2.5) == 3)
        #expect(BudgetMonthMath.jsRound(-2.5) == -2)
        #expect(BudgetMonthMath.jsRound(-2.6) == -3)
        #expect(BudgetMonthMath.amountToInteger(10.05) == 1005)
    }
}
