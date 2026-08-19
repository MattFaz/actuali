import Foundation
import Testing
@testable import Actuali

struct AgeOfMoneyEngineTests {
    private let today = { // 2026-07-11 UTC
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: 2026, month: 7, day: 11))!
    }()

    private func tx(_ id: String, date: Int, amount: Int,
                    account: String = "a1", transferAcct: String? = nil) -> Transaction {
        var t = Transaction(id: id, accountId: account, date: date, amount: amount,
                            payeeId: nil, payeeName: nil, categoryId: nil, categoryName: nil,
                            notes: nil, cleared: true, reconciled: false, transferId: nil,
                            isParent: false, parentId: nil, tombstone: false,
                            sortOrder: nil, importedPayee: nil)
        t.transferAcct = transferAcct
        return t
    }

    private func meta(start: String = "2026-01", end: String = "2026-07",
                      mode: WidgetTimeFrame.Mode = .full) -> AgeOfMoneyMeta {
        AgeOfMoneyMeta(name: nil,
                       timeFrame: WidgetTimeFrame(start: start, end: end, mode: mode),
                       conditions: nil, conditionsOp: nil, granularity: "monthly")
    }

    @Test func simpleFIFOAge() {
        // Income Jan 1, spent Jan 31 → age 30 days.
        let data = AgeOfMoneyEngine.compute(
            meta: meta(),
            transactions: [tx("i", date: 20260101, amount: 100_000),
                           tx("e", date: 20260131, amount: -50_000)],
            today: today, context: .empty)
        #expect(data.currentAge == 30)
        #expect(data.insufficientData == false)
    }

    @Test func expenseSpanningBucketsUsesLastDrainedBucketDate() {
        // 500 on Jan 1 + 500 on Feb 1; expense of 800 on Mar 1 drains both:
        // age comes from the LAST bucket touched (Feb 1) → 28 days.
        let data = AgeOfMoneyEngine.compute(
            meta: meta(),
            transactions: [tx("i1", date: 20260101, amount: 50_000),
                           tx("i2", date: 20260201, amount: 50_000),
                           tx("e", date: 20260301, amount: -80_000)],
            today: today, context: .empty)
        #expect(data.currentAge == 28)
    }

    @Test func expensesExceedingIncomeFlagInsufficientData() {
        let data = AgeOfMoneyEngine.compute(
            meta: meta(),
            transactions: [tx("i", date: 20260101, amount: 10_000),
                           tx("e", date: 20260201, amount: -50_000)],
            today: today, context: .empty)
        #expect(data.insufficientData == true)
    }

    @Test func onBudgetTransfersAreExcluded() {
        // A transfer to an ON-budget account must not create an income bucket
        // or an expense; a transfer to an OFF-budget account counts.
        let context = ConditionsFilter.Context(offBudgetAccountIds: ["off1"], accountNames: [:])
        let data = AgeOfMoneyEngine.compute(
            meta: meta(),
            transactions: [
                tx("i", date: 20260101, amount: 100_000),
                tx("t-on", date: 20260110, amount: -30_000, transferAcct: "on2"),   // excluded
                tx("t-off", date: 20260215, amount: -20_000, transferAcct: "off1"), // counts, age 45
            ],
            today: today, context: context)
        #expect(data.currentAge == 45)
    }

    @Test func headlineAveragesOnlyLastTenAgesInDisplayRange() {
        // 12 expenses, one/day starting Feb 1, all from a Jan 1 income bucket.
        // Ages: 31,32,...,42. Last 10 = 33...42, avg = 37.5 → rounds to 38.
        var txs = [tx("i", date: 20260101, amount: 1_200_000)]
        for day in 1...12 {
            txs.append(tx("e\(day)", date: 20260200 + day, amount: -100_000))
        }
        let data = AgeOfMoneyEngine.compute(meta: meta(), transactions: txs,
                                            today: today, context: .empty)
        #expect(data.currentAge == 38)
    }

    @Test func trendComparesLastTwoGraphPoints() {
        // Ages fall over months → declining trend (diff < -2).
        // e1 (Mar 1) ages from i1 (2025-01-01) → 424; the Mar point (424) is
        // carried forward through Jun. e2 (Jul 10) drains the rest of i1 then
        // i2 (Jun 1) → age 39, so the Jul point is round((424+39)/2) = 232.
        // Last two graph points: Jun 424 → Jul 232, diff -192 → .down.
        let data = AgeOfMoneyEngine.compute(
            meta: meta(),
            transactions: [
                tx("i1", date: 20250101, amount: 100_000),
                tx("e1", date: 20260301, amount: -50_000),
                tx("i2", date: 20260601, amount: 100_000),
                tx("e2", date: 20260710, amount: -60_000),
            ],
            today: today, context: .empty)
        #expect(data.trend == .down)
    }

    // MARK: - Vectors ported verbatim from upstream
    // actual/packages/desktop-client/src/components/reports/spreadsheets/
    // age-of-money-spreadsheet.test.ts (amounts used as cents; scale is
    // irrelevant to the FIFO math).

    // Upstream: "handles multiple expenses consuming buckets sequentially"
    // income 1000 on 2024-01-01; expenses -300 on Jan 10/20/30.
    // Expected ages: 9, 19, 29; insufficientData false.
    @Test func upstreamMultipleExpensesConsumingBucketsSequentially() {
        let data = AgeOfMoneyEngine.compute(
            meta: meta(start: "2024-01", end: "2024-01", mode: .static),
            transactions: [
                tx("1", date: 20240101, amount: 1000),
                tx("2", date: 20240110, amount: -300),
                tx("3", date: 20240120, amount: -300),
                tx("4", date: 20240130, amount: -300),
            ],
            today: today, context: .empty)
        #expect(data.insufficientData == false)
        // Headline = avg of ages (9 + 19 + 29) / 3 = 19; single Jan point.
        #expect(data.currentAge == 19)
        #expect(data.points == [.init(monthLabel: "Jan 2024", age: 19)])
    }

    // Upstream: "round-trip: money leaves to off-budget and returns later"
    //   Jan 1:  Paycheck +3000 (income)
    //   Jan 10: Transfer -1000 to investment (off-budget spending) → age 9
    //   Mar 1:  Transfer +1000 from investment (off-budget income, new bucket)
    //   Mar 15: Groceries -2500 (drains Jan 1 then Mar 1 bucket) → age 14
    // Expected ages: 9 (2024-01-10), 14 (2024-03-15); insufficientData false.
    @Test func upstreamRoundTripOffBudgetTransfer() {
        let context = ConditionsFilter.Context(offBudgetAccountIds: ["invest"], accountNames: [:])
        let txs = [
            tx("paycheck", date: 20240101, amount: 3000),
            tx("to-investment", date: 20240110, amount: -1000, transferAcct: "invest"),
            tx("from-investment", date: 20240301, amount: 1000, transferAcct: "invest"),
            tx("groceries", date: 20240315, amount: -2500),
        ]
        let data = AgeOfMoneyEngine.compute(
            meta: meta(start: "2024-01", end: "2024-03", mode: .static),
            transactions: txs, today: today, context: context)
        #expect(data.insufficientData == false)
        // Jan point = 9; Feb carries 9; Mar point = round((9 + 14) / 2) = 12.
        #expect(data.points == [.init(monthLabel: "Jan 2024", age: 9),
                                .init(monthLabel: "Feb 2024", age: 9),
                                .init(monthLabel: "Mar 2024", age: 12)])
        #expect(data.currentAge == 12)

        // Narrow the display range to March only: full history still feeds
        // the FIFO, and the lone in-range age is exactly 14.
        let marchOnly = AgeOfMoneyEngine.compute(
            meta: meta(start: "2024-03", end: "2024-03", mode: .static),
            transactions: txs, today: today, context: context)
        #expect(marchOnly.currentAge == 14)
        #expect(marchOnly.insufficientData == false)
    }

    // MARK: - Edge-case pins

    @Test func expenseWithNoIncomeAtAllYieldsNilAgeAndInsufficientData() {
        // No bucket is ever touched: no age is recorded (currentAge nil,
        // no graph points), but the uncovered expense flags insufficient data.
        let data = AgeOfMoneyEngine.compute(
            meta: meta(),
            transactions: [tx("e", date: 20260115, amount: -50_000)],
            today: today, context: .empty)
        #expect(data.currentAge == nil)
        #expect(data.points.isEmpty)
        #expect(data.insufficientData == true)
    }

    @Test func expenseDatedBeforeOnlyIncomeBucketClampsAgeToZero() {
        // The expense (Jan 10) drains the Feb 1 bucket; the raw day distance
        // is -22 but upstream clamps with max(0, days) → age 0.
        let data = AgeOfMoneyEngine.compute(
            meta: meta(),
            transactions: [tx("e", date: 20260110, amount: -50_000),
                           tx("i", date: 20260201, amount: 100_000)],
            today: today, context: .empty)
        #expect(data.currentAge == 0)
        #expect(data.insufficientData == false)
    }

    @Test func sameDayIncomeAndExpenseYieldAgeZero() {
        // Upstream: "handles income and expenses on the same day (age = 0)".
        let data = AgeOfMoneyEngine.compute(
            meta: meta(),
            transactions: [tx("i", date: 20260115, amount: 100_000),
                           tx("e", date: 20260115, amount: -50_000)],
            today: today, context: .empty)
        #expect(data.currentAge == 0)
        #expect(data.insufficientData == false)
    }

    @Test func transactionsAfterTodayAreExcludedFromThePool() {
        // fixedEnd = min(resolved end, today) — a future-dated expense
        // (Aug 1 with today = Jul 11) must not reach the FIFO at all.
        let data = AgeOfMoneyEngine.compute(
            meta: meta(),
            transactions: [tx("i", date: 20260101, amount: 100_000),
                           tx("e", date: 20260801, amount: -50_000)],
            today: today, context: .empty)
        #expect(data.currentAge == nil)
        #expect(data.points.isEmpty)
        #expect(data.insufficientData == false)
    }
}
