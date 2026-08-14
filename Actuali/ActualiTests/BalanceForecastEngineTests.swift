import Foundation
import Testing
@testable import Actuali

@MainActor
struct BalanceForecastEngineTests {

    // Fixed "now": 2026-05-14 (UTC).
    private var asOf: Date {
        var c = DateComponents(); c.year = 2026; c.month = 5; c.day = 14
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func tx(date: Int, amount: Int, account: String = "a1", schedule: String? = nil) -> Transaction {
        var t = Transaction(
            id: UUID().uuidString,
            accountId: account, date: date, amount: amount,
            payeeId: nil, payeeName: nil, categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false,
            transferId: nil, isParent: false, parentId: nil,
            tombstone: false, sortOrder: nil, importedPayee: nil
        )
        t.schedule = schedule
        return t
    }

    private func schedule(
        id: String = "s1",
        nextDate: Int,
        account: String = "a1",
        payee: String? = nil,
        amount: Int,
        dateCondition: ScheduleDateCondition
    ) -> Schedule {
        Schedule(
            id: id, name: nil,
            nextDate: DayDate(yyyymmdd: nextDate)!,
            nextDateRowId: "nd-\(id)", baseNextDateTs: nil,
            accountId: account, payeeId: payee, categoryId: nil,
            amount: .fixed(amount), dateCondition: dateCondition
        )
    }

    private func monthlyRecurrence(startingOn iso: String) -> ScheduleDateCondition {
        .recurring(RecurConfig(json: ["frequency": "monthly", "start": iso])!)
    }

    private func meta(
        accounts: [String]? = nil,
        start: String, end: String,
        granularity: BalanceForecastMeta.Granularity = .monthly,
        source: BalanceForecastMeta.Source? = nil
    ) -> BalanceForecastMeta {
        BalanceForecastMeta(
            name: nil, startDate: nil, endDate: nil, accounts: accounts,
            conditions: nil, conditionsOp: nil,
            timeFrame: WidgetTimeFrame(start: start, end: end, mode: .static),
            granularity: granularity, source: source
        )
    }

    // MARK: - Historical balances

    // Upstream: "combines balances across accounts for monthly data".
    @Test func monthlyHistoryCombinesAccounts() {
        let transactions = [
            tx(date: 20260301, amount: 1000, account: "checking"),
            tx(date: 20260301, amount: 500, account: "savings"),
            tx(date: 20260401, amount: -100, account: "checking"),
            tx(date: 20260401, amount: 200, account: "savings")
        ]
        let result = BalanceForecastEngine.compute(
            meta: meta(start: "2026-03", end: "2026-04"),
            transactions: transactions, today: asOf
        )
        #expect(result.points == [
            BalanceForecastPoint(date: utcDate(2026, 3, 31), balanceCents: 1500, isForecast: false),
            BalanceForecastPoint(date: utcDate(2026, 4, 30), balanceCents: 1600, isForecast: false)
        ])
    }

    @Test func accountSelectionRestrictsBalances() {
        let transactions = [
            tx(date: 20260301, amount: 1000, account: "checking"),
            tx(date: 20260301, amount: 500, account: "savings"),
            tx(date: 20260401, amount: -100, account: "checking")
        ]
        let result = BalanceForecastEngine.compute(
            meta: meta(accounts: ["checking"], start: "2026-03", end: "2026-04"),
            transactions: transactions, today: asOf
        )
        #expect(result.points.map(\.balanceCents) == [1000, 900])
    }

    // Upstream: "carries monthly balances through the full end month for daily data".
    @Test func dailyCarriesBalanceAcrossDays() {
        let transactions = [
            tx(date: 20260301, amount: 1000),
            tx(date: 20260401, amount: 200)
        ]
        let result = BalanceForecastEngine.compute(
            meta: meta(start: "2026-03", end: "2026-04", granularity: .daily),
            transactions: transactions, today: asOf
        )
        #expect(result.points.count == 61)
        #expect(result.points[0] == BalanceForecastPoint(date: utcDate(2026, 3, 1), balanceCents: 1000, isForecast: false))
        #expect(result.points[30].balanceCents == 1000)  // Mar 31
        #expect(result.points[31].balanceCents == 1200)  // Apr 1
        #expect(result.points.last == BalanceForecastPoint(date: utcDate(2026, 4, 30), balanceCents: 1200, isForecast: false))
    }

    // Upstream: "preserves exact day-shaped bounds" + "carries the balance
    // forward from points before a day-shaped start".
    @Test func dailyDayShapedBoundsStayExact() {
        let transactions = [
            tx(date: 20260301, amount: 1000),
            tx(date: 20260315, amount: -200)
        ]
        let result = BalanceForecastEngine.compute(
            meta: meta(start: "2026-03-10", end: "2026-03-20", granularity: .daily),
            transactions: transactions, today: asOf
        )
        #expect(result.points.count == 11)
        #expect(result.points.first == BalanceForecastPoint(date: utcDate(2026, 3, 10), balanceCents: 1000, isForecast: false))
        #expect(result.points.last == BalanceForecastPoint(date: utcDate(2026, 3, 20), balanceCents: 800, isForecast: false))
    }

    // MARK: - Schedules source

    @Test func schedulesSourceProjectsRecurringOccurrences() {
        let transactions = [tx(date: 20260410, amount: 100_000)]
        let schedules = [schedule(nextDate: 20260520, amount: -5000, dateCondition: monthlyRecurrence(startingOn: "2026-05-20"))]
        let result = BalanceForecastEngine.compute(
            meta: meta(start: "2026-04", end: "2026-07"),
            transactions: transactions, schedules: schedules, today: asOf
        )
        #expect(result.points.map(\.balanceCents) == [100_000, 95_000, 90_000, 85_000])
        #expect(result.points.map(\.isForecast) == [false, true, true, true])
    }

    @Test func pastDueOccurrencesDoNotProject() {
        // nextDate 2026-05-01 is before today (2026-05-14): upstream's
        // firstForecastDate excludes it; only Jun/Jul occurrences project.
        let schedules = [schedule(nextDate: 20260501, amount: -5000, dateCondition: monthlyRecurrence(startingOn: "2026-05-01"))]
        let result = BalanceForecastEngine.compute(
            meta: meta(start: "2026-05", end: "2026-07"),
            transactions: [], schedules: schedules, today: asOf
        )
        #expect(result.points.map(\.balanceCents) == [0, -5000, -10_000])
    }

    @Test func postedOccurrenceIsNotDoubleCounted() {
        // The May 20 occurrence was already posted (transaction linked to the
        // schedule): only the posted transaction counts, plus the Jun/Jul
        // projections.
        let transactions = [tx(date: 20260520, amount: -5000, schedule: "s1")]
        let schedules = [schedule(nextDate: 20260520, amount: -5000, dateCondition: monthlyRecurrence(startingOn: "2026-05-20"))]
        let result = BalanceForecastEngine.compute(
            meta: meta(start: "2026-05", end: "2026-07"),
            transactions: transactions, schedules: schedules, today: asOf
        )
        #expect(result.points.map(\.balanceCents) == [-5000, -10_000, -15_000])
    }

    @Test func transferScheduleProjectsBothLegs() {
        let schedules = [schedule(nextDate: 20260520, payee: "p-transfer", amount: -25_000, dateCondition: .fixed(DayDate(yyyymmdd: 20260520)!))]
        let transferMap = ["p-transfer": "savings"]

        // Both accounts included: the legs cancel out.
        let combined = BalanceForecastEngine.compute(
            meta: meta(start: "2026-05", end: "2026-05"),
            transactions: [], schedules: schedules,
            transferAccountsByPayeeId: transferMap, today: asOf
        )
        #expect(combined.points.map(\.balanceCents) == [0])

        // Only the transfer side selected: its leg still projects.
        let savingsOnly = BalanceForecastEngine.compute(
            meta: meta(accounts: ["savings"], start: "2026-05", end: "2026-05"),
            transactions: [], schedules: schedules,
            transferAccountsByPayeeId: transferMap, today: asOf
        )
        #expect(savingsOnly.points.map(\.balanceCents) == [25_000])
    }

    // MARK: - Tracking-budget source

    @Test func trackingBudgetSourceProjectsFromBudgetedTotals() {
        let transactions = [
            tx(date: 20260110, amount: 100_000, account: "checking"),
            tx(date: 20260110, amount: 999, account: "offbudget")  // excluded from starting balance
        ]
        let months = [
            BalanceForecastBudgetMonth(month: 202605, budgetedIncomeCents: 20_000, budgetedExpensesCents: 15_000),
            BalanceForecastBudgetMonth(month: 202606, budgetedIncomeCents: 0, budgetedExpensesCents: 10_000)
        ]
        let result = BalanceForecastEngine.compute(
            meta: meta(start: "2026-05", end: "2026-07", source: .trackingBudget),
            transactions: transactions, trackingBudgetMonths: months,
            offBudgetAccountIds: ["offbudget"], today: asOf
        )
        // May: 100000 + 5000; Jun: -10000; Jul has no budget rows → carries.
        #expect(result.points.map(\.balanceCents) == [105_000, 95_000, 95_000])
        #expect(result.points.map(\.isForecast) == [true, true, true])
    }

    // MARK: - Boundaries and edge cases

    @Test func dailyBoundaryBetweenHistoryAndForecast() {
        let transactions = [tx(date: 20260512, amount: 1000)]
        let schedules = [schedule(nextDate: 20260516, amount: -300, dateCondition: .fixed(DayDate(yyyymmdd: 20260516)!))]
        let result = BalanceForecastEngine.compute(
            meta: meta(start: "2026-05-10", end: "2026-05-18", granularity: .daily),
            transactions: transactions, schedules: schedules, today: asOf
        )
        let byDay = Dictionary(uniqueKeysWithValues: result.points.map { ($0.date, $0) })
        #expect(byDay[utcDate(2026, 5, 14)]?.isForecast == false)
        #expect(byDay[utcDate(2026, 5, 15)]?.isForecast == true)
        #expect(byDay[utcDate(2026, 5, 15)]?.balanceCents == 1000)
        #expect(byDay[utcDate(2026, 5, 16)]?.balanceCents == 700)
        #expect(byDay[utcDate(2026, 5, 18)]?.balanceCents == 700)
    }

    @Test func emptyAccountSelectionYieldsNoPoints() {
        let result = BalanceForecastEngine.compute(
            meta: meta(accounts: [], start: "2026-05", end: "2026-07"),
            transactions: [tx(date: 20260501, amount: 1000)], today: asOf
        )
        #expect(result.points.isEmpty)
    }

    @Test func defaultTimeFrameIsCurrentMonthPlusElevenMonths() {
        // Card default (BalanceForecastCard.tsx): current month → +11 months.
        let result = BalanceForecastEngine.compute(
            meta: nil, transactions: [tx(date: 20260101, amount: 4200)], today: asOf
        )
        #expect(result.points.count == 12)
        #expect(result.points.first?.date == utcDate(2026, 5, 31))
        #expect(result.points.last?.date == utcDate(2027, 4, 30))
        #expect(result.points.allSatisfy { $0.balanceCents == 4200 })
    }
}
