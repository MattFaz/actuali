import Foundation
import Testing
@testable import Actuali

@MainActor
struct CalendarEngineTests {

    private var asOf: Date {
        var c = DateComponents(); c.year = 2026; c.month = 5; c.day = 14
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func tx(date: Int, amount: Int, categoryId: String? = nil, tombstone: Bool = false) -> Transaction {
        Transaction(
            id: UUID().uuidString,
            accountId: "a1", date: date, amount: amount,
            payeeId: nil, payeeName: nil, categoryId: categoryId, categoryName: nil,
            notes: nil, cleared: false, reconciled: false,
            transferId: nil, isParent: false, parentId: nil,
            tombstone: tombstone, sortOrder: nil, importedPayee: nil
        )
    }

    private func meta(
        conditions: [WidgetRuleCondition]? = nil,
        conditionsOp: String? = nil,
        timeFrame: WidgetTimeFrame? = nil
    ) -> CalendarMeta {
        CalendarMeta(name: nil, conditions: conditions, conditionsOp: conditionsOp, timeFrame: timeFrame)
    }

    private var mayTimeFrame: WidgetTimeFrame {
        WidgetTimeFrame(start: "2026-05", end: "2026-05", mode: .static)
    }

    private func cell(_ data: CalendarData, month: Int, day: Int) -> CalendarDayCell? {
        data.months[month].days.first { $0.dayOfMonth == day }
    }

    @Test func bucketsIncomeAndExpensePerDay() {
        let transactions = [
            tx(date: 20260510, amount: 5000),
            tx(date: 20260510, amount: -3000),
            tx(date: 20260512, amount: -1000)
        ]
        let result = CalendarEngine.compute(meta: meta(timeFrame: mayTimeFrame),
                                            transactions: transactions,
                                            today: asOf, firstDayOfWeekIdx: 0)
        #expect(result.months.count == 1)
        #expect(cell(result, month: 0, day: 10)?.incomeCents == 5000)
        #expect(cell(result, month: 0, day: 10)?.expenseCents == 3000)
        #expect(cell(result, month: 0, day: 12)?.expenseCents == 1000)
        #expect(result.months[0].totalIncomeCents == 5000)
        #expect(result.months[0].totalExpenseCents == 4000)
        // Bar sizes are the day's share of the month total (upstream getBarLength).
        #expect(cell(result, month: 0, day: 10)?.incomeSize == 100)
        #expect(cell(result, month: 0, day: 10)?.expenseSize == 75)
        #expect(cell(result, month: 0, day: 12)?.expenseSize == 25)
    }

    @Test func staticTimeFrameExcludesOutsideRange() {
        let transactions = [
            tx(date: 20260430, amount: -9999),   // April — outside
            tx(date: 20260501, amount: -100),
            tx(date: 20260601, amount: -9999)    // June — outside
        ]
        let result = CalendarEngine.compute(meta: meta(timeFrame: mayTimeFrame),
                                            transactions: transactions,
                                            today: asOf, firstDayOfWeekIdx: 0)
        #expect(result.months.count == 1)
        #expect(result.months[0].totalExpenseCents == 100)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day], from: result.months[0].monthStart)
        #expect(comps.year == 2026 && comps.month == 5 && comps.day == 1)
    }

    @Test func multiMonthRangeSumsOverallTotals() {
        let transactions = [
            tx(date: 20260410, amount: -1000),
            tx(date: 20260510, amount: -2000),
            tx(date: 20260511, amount: 500)
        ]
        let tf = WidgetTimeFrame(start: "2026-04", end: "2026-05", mode: .static)
        let result = CalendarEngine.compute(meta: meta(timeFrame: tf),
                                            transactions: transactions,
                                            today: asOf, firstDayOfWeekIdx: 0)
        #expect(result.months.count == 2)
        #expect(result.totalExpenseCents == 3000)
        #expect(result.totalIncomeCents == 500)
    }

    @Test func conditionsFilterTransactions() {
        let condition = WidgetRuleCondition(
            op: "is", field: "category",
            value: AnyCodable(rawJSON: Data("\"c1\"".utf8)),
            options: nil, customName: nil
        )
        let transactions = [
            tx(date: 20260510, amount: -3000, categoryId: "c1"),
            tx(date: 20260511, amount: -7000, categoryId: "c2")
        ]
        let result = CalendarEngine.compute(meta: meta(conditions: [condition], conditionsOp: "and", timeFrame: mayTimeFrame),
                                            transactions: transactions,
                                            today: asOf, firstDayOfWeekIdx: 0)
        #expect(result.months[0].totalExpenseCents == 3000)
        #expect(cell(result, month: 0, day: 11)?.expenseCents == 0)
    }

    @Test func tombstonedTransactionsExcluded() {
        let transactions = [
            tx(date: 20260510, amount: -3000, tombstone: true),
            tx(date: 20260511, amount: -1000)
        ]
        let result = CalendarEngine.compute(meta: meta(timeFrame: mayTimeFrame),
                                            transactions: transactions,
                                            today: asOf, firstDayOfWeekIdx: 0)
        #expect(result.months[0].totalExpenseCents == 1000)
    }

    // May 2026 starts on a Friday: Sunday-start grids need 5 leading padding
    // cells (42 total), Monday-start grids need 4 (35 total).
    @Test func gridAlignsToFirstDayOfWeek() {
        let sunday = CalendarEngine.compute(meta: meta(timeFrame: mayTimeFrame),
                                            transactions: [], today: asOf, firstDayOfWeekIdx: 0)
        #expect(sunday.months[0].days.count == 42)
        #expect(sunday.months[0].days.prefix(5).allSatisfy { $0.dayOfMonth == nil })
        #expect(sunday.months[0].days[5].dayOfMonth == 1)
        #expect(sunday.firstDayOfWeekIdx == 0)

        let monday = CalendarEngine.compute(meta: meta(timeFrame: mayTimeFrame),
                                            transactions: [], today: asOf, firstDayOfWeekIdx: 1)
        #expect(monday.months[0].days.count == 35)
        #expect(monday.months[0].days[4].dayOfMonth == 1)

        // Out-of-range index falls back to Sunday, matching upstream.
        let invalid = CalendarEngine.compute(meta: meta(timeFrame: mayTimeFrame),
                                             transactions: [], today: asOf, firstDayOfWeekIdx: 9)
        #expect(invalid.firstDayOfWeekIdx == 0)
        #expect(invalid.months[0].days.count == 42)
    }

    @Test func nilTimeFrameDefaultsToCurrentMonth() {
        let transactions = [
            tx(date: 20260520, amount: -1500),   // later in the current month still counts
            tx(date: 20260410, amount: -9999)    // prior month excluded
        ]
        let result = CalendarEngine.compute(meta: nil, transactions: transactions,
                                            today: asOf, firstDayOfWeekIdx: 0)
        #expect(result.months.count == 1)
        #expect(result.months[0].totalExpenseCents == 1500)
    }
}
