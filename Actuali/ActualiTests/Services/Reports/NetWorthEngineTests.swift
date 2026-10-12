import Foundation
import Testing
@testable import Actuali

@MainActor
struct NetWorthEngineTests {
    private var asOf: Date {
        var c = DateComponents(); c.year = 2026; c.month = 5; c.day = 14
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func tx(date: Int, amount: Int, tombstone: Bool = false) -> Transaction {
        Transaction(
            id: UUID().uuidString,
            accountId: "a1", date: date, amount: amount,
            payeeId: nil, payeeName: nil, categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false,
            transferId: nil, isParent: false, parentId: nil,
            tombstone: tombstone, sortOrder: nil, importedPayee: nil
        )
    }

    private func utcDate(_ day: String) -> Date {
        ISO8601DateFormatter().date(from: "\(day)T00:00:00Z")!
    }

    @Test func emptyTransactionsReturnsZeros() {
        let meta = NetWorthMeta(name: nil, timeFrame: nil, conditions: nil,
                                conditionsOp: nil, interval: .monthly, mode: nil)
        let result = NetWorthEngine.compute(meta: meta, transactions: [], today: asOf)
        #expect(!result.points.isEmpty)
        #expect(result.points.allSatisfy { $0.balanceCents == 0 })
    }

    @Test func cumulativeBalanceAcrossMonths() {
        let transactions = [
            tx(date: 20_260_115, amount: 10000),
            tx(date: 20_260_215, amount: 10000),
            tx(date: 20_260_315, amount: 10000),
        ]
        let meta = NetWorthMeta(name: nil,
                                timeFrame: WidgetTimeFrame(start: nil, end: nil, mode: .yearToDate),
                                conditions: nil, conditionsOp: nil,
                                interval: .monthly, mode: nil)
        let result = NetWorthEngine.compute(meta: meta, transactions: transactions, today: asOf)
        // Last point covers May 2026 — all 3 transactions counted.
        #expect(result.points.last?.balanceCents == 30000)
    }

    @Test func tombstonedTransactionsExcluded() {
        let transactions = [
            tx(date: 20_260_115, amount: 10000),
            tx(date: 20_260_215, amount: 10000, tombstone: true),
        ]
        // Use yearToDate so Jan/Feb transactions are in range; nil timeFrame
        // now defaults to current month.
        let meta = NetWorthMeta(name: nil,
                                timeFrame: WidgetTimeFrame(start: nil, end: nil, mode: .yearToDate),
                                conditions: nil, conditionsOp: nil,
                                interval: .monthly, mode: nil)
        let result = NetWorthEngine.compute(meta: meta, transactions: transactions, today: asOf)
        #expect(result.points.last?.balanceCents == 10000)
    }

    @Test func monthlyIntervalProducesFivePointsForYearToDate() {
        // For yearToDate from May 14 2026, expect 5 monthly points (Jan, Feb, Mar, Apr, May).
        let meta = NetWorthMeta(name: nil,
                                timeFrame: WidgetTimeFrame(start: nil, end: nil, mode: .yearToDate),
                                conditions: nil, conditionsOp: nil,
                                interval: .monthly, mode: nil)
        let result = NetWorthEngine.compute(meta: meta, transactions: [], today: asOf)
        #expect(result.points.count == 5)
    }

    @Test(arguments: [
        (NetWorthMeta.Interval.daily, ["2026-01-30", "2026-01-31", "2026-02-01", "2026-02-02"], [100, 150, 130, 130]),
        (.weekly, ["2026-01-31"], [150]),
        (.monthly, ["2026-01-31", "2026-02-02"], [150, 130]),
        (.yearly, ["2026-02-02"], [130]),
    ])
    func shuffledTransactionsPreserveBoundaryBalances(
        interval: NetWorthMeta.Interval, expectedDates: [String], expectedBalances: [Int]
    ) {
        let duplicate = tx(date: 20_260_131, amount: 25)
        let transactions = [
            tx(date: 20_260_203, amount: 999),
            duplicate,
            tx(date: 20_251_231, amount: 100),
            tx(date: 20_260_201, amount: -20),
            duplicate,
        ]
        let meta = NetWorthMeta(name: nil,
                                timeFrame: WidgetTimeFrame(start: "2026-01-30", end: "2026-02-02", mode: .static),
                                conditions: nil, conditionsOp: nil,
                                interval: interval, mode: nil)
        let result = NetWorthEngine.compute(meta: meta, transactions: transactions, today: asOf)
        #expect(result.points.map(\.date) == expectedDates.map { utcDate($0) })
        #expect(result.points.map(\.balanceCents) == expectedBalances)
    }

    @Test func nilMetaUsesSingleMonthlyBoundary() {
        let transactions = [
            tx(date: 20_260_601, amount: 999),
            tx(date: 20_260_430, amount: 100),
            tx(date: 20_260_531, amount: 25),
        ]
        let result = NetWorthEngine.compute(meta: nil, transactions: transactions, today: asOf)
        #expect(result.points == [NetWorthPoint(date: utcDate("2026-05-31"), balanceCents: 125)])
    }

    @Test func reversedDailyRangeReturnsNoPoints() {
        let meta = NetWorthMeta(name: nil,
                                timeFrame: WidgetTimeFrame(start: "2026-02-02", end: "2026-01-30", mode: .static),
                                conditions: nil, conditionsOp: nil,
                                interval: .daily, mode: nil)
        let result = NetWorthEngine.compute(meta: meta, transactions: [tx(date: 20_260_101, amount: 100)], today: asOf)
        #expect(result.points.isEmpty)
    }
}
