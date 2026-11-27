import Foundation
import Testing
@testable import Actuali

struct MonthStartRuleTests {
    private func date(_ value: String) -> Date {
        CanonicalDateParser.parseMonthOrDay(value)!
    }

    @Test func clampsToTheLastDayOfShortMonths() {
        let rule = MonthStartRule(day: 31)
        #expect(rule.start(for: date("2024-02")) == date("2024-02-29"))
        #expect(rule.start(for: date("2025-02")) == date("2025-02-28"))
        #expect(rule.start(for: date("2026-04")) == date("2026-04-30"))
    }

    @Test func previousWorkingDayCrossesMonthAndSkipsHoliday() {
        let rule = MonthStartRule(day: 1, adjustment: .previousWorkingDay,
                                  weekendDays: [6, 7], holidays: [date("2026-07-30")])
        let (start, end) = rule.range(relativeTo: date("2026-07-29"), first: 0, last: 0)
        #expect(start == date("2026-07-29"))
        #expect(end == date("2026-08-31"))
    }

    @Test func nextWorkingDayCrossesMonth() {
        let rule = MonthStartRule(day: 31, adjustment: .nextWorkingDay, holidays: [date("2026-08-31")])
        let anchor = rule.anchor(containing: date("2026-08-31"))
        #expect(anchor == date("2026-07"))
        #expect(rule.start(for: date("2026-08")) == date("2026-09-01"))
    }

    @Test func slidingWindowUsesConsecutiveAdjustedBoundaries() throws {
        let rule = MonthStartRule(day: 31, adjustment: .nextWorkingDay, holidays: [date("2026-08-31")])
        let frame = WidgetTimeFrame(start: "2026-04", end: "2026-05", mode: .slidingWindow)
        let (start, end) = try #require(TimeFrame.adjustedRange(frame, asOf: date("2026-09-02"), rule: rule))
        #expect(rule.periods(from: start, through: end) == [
            date("2026-07-31")...date("2026-08-31"),
            date("2026-09-01")...date("2026-09-29"),
        ])
        let fixed = WidgetTimeFrame(start: "2026-04", end: "2026-05", mode: .static)
        #expect(TimeFrame.adjustedRange(fixed, asOf: date("2026-09-02"), rule: rule) == nil)
    }

    @Test func customMonthPresetUsesPriorPeriod() {
        let (start, end) = ReportDateRange.resolve(
            dateRange: "Last month", dateStatic: false,
            startDate: nil, endDate: nil, includeCurrent: false,
            earliest: date("2025-01-01"), latest: nil,
            today: date("2026-08-14"), firstDayOfWeekIdx: 0,
            monthStartRule: MonthStartRule(day: 15)
        )
        #expect(start == date("2026-06-15"))
        #expect(end == date("2026-07-14"))
    }

    @Test func rulesAreStoredPerBudget() {
        let budgetID = UUID().uuidString
        defer { UserDefaults.standard.removeObject(forKey: "reportMonthStartRule.\(budgetID)") }
        let rule = MonthStartRule(day: 15, adjustment: .nextWorkingDay, weekendDays: [6, 7], holidays: [date("2026-08-16")])
        rule.save(for: budgetID)
        #expect(MonthStartRule.load(for: budgetID) == rule)
        #expect(MonthStartRule.load(for: UUID().uuidString) == .calendarMonth)
    }
}
