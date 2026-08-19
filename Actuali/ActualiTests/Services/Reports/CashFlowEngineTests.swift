import Foundation
import Testing
@testable import Actuali

@MainActor
struct CashFlowEngineTests {

    private var asOf: Date {
        var c = DateComponents(); c.year = 2026; c.month = 5; c.day = 14
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func tx(date: Int, amount: Int,
                    account: String = "a1",
                    transferAcct: String? = nil) -> Transaction {
        Transaction(
            id: UUID().uuidString,
            accountId: account, date: date, amount: amount,
            payeeId: nil, payeeName: nil, categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false,
            transferId: nil, isParent: false, parentId: nil,
            tombstone: false, sortOrder: nil, importedPayee: nil,
            transferAcct: transferAcct
        )
    }

    private func month(of date: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.component(.month, from: date)
    }

    @Test func splitsPositiveAndNegativeAmounts() {
        let transactions = [
            tx(date: 20260301, amount: 50000),
            tx(date: 20260315, amount: -20000),
            tx(date: 20260320, amount: -10000)
        ]
        let meta = CashFlowMeta(name: nil,
                                timeFrame: WidgetTimeFrame(start: nil, end: nil, mode: .yearToDate),
                                conditions: nil, conditionsOp: nil, showBalance: false)
        let result = CashFlowEngine.compute(meta: meta, transactions: transactions, today: asOf)

        let marchPoint = result.points.first { month(of: $0.periodStart) == 3 }
        #expect(marchPoint?.incomeCents == 50000)
        #expect(marchPoint?.expenseCents == 30000)
    }

    @Test func emptyReturnsZeroPoints() {
        let meta = CashFlowMeta(name: nil, timeFrame: nil,
                                conditions: nil, conditionsOp: nil, showBalance: false)
        let result = CashFlowEngine.compute(meta: meta, transactions: [], today: asOf)
        #expect(result.points.allSatisfy { $0.incomeCents == 0 && $0.expenseCents == 0 })
    }

    @Test func excludesTransferLegsFromIncomeAndExpense() {
        // A €100.00 move between two on-budget accounts produces equal and
        // opposite legs; counting them inflates BOTH income and expense
        // (GH #15: totals over 2x). The WebUI's cash flow filters
        // payee.transfer_acct != null, so both legs must be excluded.
        let transactions = [
            tx(date: 20260310, amount: 10000, account: "savings", transferAcct: "checking"),
            tx(date: 20260310, amount: -10000, account: "checking", transferAcct: "savings"),
            tx(date: 20260312, amount: 5000),
            tx(date: 20260313, amount: -2000)
        ]
        let meta = CashFlowMeta(name: nil,
                                timeFrame: WidgetTimeFrame(start: nil, end: nil, mode: .yearToDate),
                                conditions: nil, conditionsOp: nil, showBalance: false)
        let result = CashFlowEngine.compute(meta: meta, transactions: transactions, today: asOf)

        let marchPoint = result.points.first { month(of: $0.periodStart) == 3 }
        #expect(marchPoint?.incomeCents == 5000)
        #expect(marchPoint?.expenseCents == 2000)
    }

    @Test func excludesOffBudgetAccounts() {
        // The WebUI's cash flow filters account.offbudget == false; tracking
        // account activity must not count toward income or expense.
        let transactions = [
            tx(date: 20260305, amount: 7000),
            tx(date: 20260306, amount: 90000, account: "brokerage"),
            tx(date: 20260307, amount: -40000, account: "brokerage")
        ]
        let meta = CashFlowMeta(name: nil,
                                timeFrame: WidgetTimeFrame(start: nil, end: nil, mode: .yearToDate),
                                conditions: nil, conditionsOp: nil, showBalance: false)
        let result = CashFlowEngine.compute(meta: meta,
                                            transactions: transactions,
                                            offBudgetAccountIds: ["brokerage"],
                                            today: asOf)

        let marchPoint = result.points.first { month(of: $0.periodStart) == 3 }
        #expect(marchPoint?.incomeCents == 7000)
        #expect(marchPoint?.expenseCents == 0)
    }

    @Test func excludesTombstonedAndOutOfRange() {
        let transactions = [
            tx(date: 20260301, amount: 1000),   // March 2026 - in range
            tx(date: 20251201, amount: 9999),   // Dec 2025 - out of range
            Transaction(id: "tomb", accountId: "a1", date: 20260301, amount: 5000,
                        payeeId: nil, payeeName: nil, categoryId: nil, categoryName: nil,
                        notes: nil, cleared: false, reconciled: false,
                        transferId: nil, isParent: false, parentId: nil,
                        tombstone: true, sortOrder: nil, importedPayee: nil)
        ]
        let meta = CashFlowMeta(name: nil,
                                timeFrame: WidgetTimeFrame(start: nil, end: nil, mode: .yearToDate),
                                conditions: nil, conditionsOp: nil, showBalance: false)
        let result = CashFlowEngine.compute(meta: meta, transactions: transactions, today: asOf)

        let marchPoint = result.points.first { month(of: $0.periodStart) == 3 }
        #expect(marchPoint?.incomeCents == 1000)
        #expect(marchPoint?.expenseCents == 0)
    }
}
