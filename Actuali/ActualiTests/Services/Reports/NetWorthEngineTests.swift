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

    @Test func emptyTransactionsReturnsZeros() {
        let meta = NetWorthMeta(name: nil, timeFrame: nil, conditions: nil,
                                conditionsOp: nil, interval: .monthly, mode: nil)
        let result = NetWorthEngine.compute(meta: meta, transactions: [], today: asOf)
        #expect(!result.points.isEmpty)
        #expect(result.points.allSatisfy { $0.balanceCents == 0 })
    }

    @Test func cumulativeBalanceAcrossMonths() {
        let transactions = [
            tx(date: 20260115, amount: 10000),
            tx(date: 20260215, amount: 10000),
            tx(date: 20260315, amount: 10000)
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
            tx(date: 20260115, amount: 10000),
            tx(date: 20260215, amount: 10000, tombstone: true)
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
}
