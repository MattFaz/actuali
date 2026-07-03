import Foundation
import Testing
@testable import Actuali

@MainActor
struct SummaryEngineTests {

    private var asOf: Date {
        var c = DateComponents(); c.year = 2026; c.month = 5; c.day = 14
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    private func tx(date: Int, amount: Int, category: String? = nil, tombstone: Bool = false) -> Transaction {
        Transaction(
            id: UUID().uuidString,
            accountId: "a1",
            date: date,
            amount: amount,
            payeeId: nil,
            payeeName: nil,
            categoryId: category,
            categoryName: nil,
            notes: nil,
            cleared: false,
            reconciled: false,
            transferId: nil,
            isParent: false,
            parentId: nil,
            tombstone: tombstone,
            sortOrder: nil,
            importedPayee: nil
        )
    }

    @Test func sumsTransactionsInRange() {
        let transactions = [
            tx(date: 20260301, amount: -1000),
            tx(date: 20260315, amount: -2000),
            tx(date: 20260420, amount: -500)
        ]
        let meta = SummaryMeta(
            name: "Spending YTD",
            timeFrame: WidgetTimeFrame(start: nil, end: nil, mode: .yearToDate),
            conditions: nil,
            conditionsOp: nil,
            content: nil
        )
        let result = SummaryEngine.compute(meta: meta, transactions: transactions, today: asOf)
        #expect(result.totalCents == -3500)
    }

    @Test func excludesTransactionsOutsideRange() {
        let transactions = [
            tx(date: 20260101, amount: -1000),
            tx(date: 20251231, amount: -9999)  // prior year
        ]
        let meta = SummaryMeta(
            name: nil,
            timeFrame: WidgetTimeFrame(start: nil, end: nil, mode: .yearToDate),
            conditions: nil,
            conditionsOp: nil,
            content: nil
        )
        let result = SummaryEngine.compute(meta: meta, transactions: transactions, today: asOf)
        #expect(result.totalCents == -1000)
    }

    @Test func excludesTombstonedTransactions() {
        let transactions = [
            tx(date: 20260301, amount: -1000),
            tx(date: 20260302, amount: -2000, tombstone: true)
        ]
        // Use yearToDate so March transactions are in range. (nil timeFrame
        // now defaults to current month per upstream Actual semantics.)
        let meta = SummaryMeta(name: nil,
                                timeFrame: WidgetTimeFrame(start: nil, end: nil, mode: .yearToDate),
                                conditions: nil, conditionsOp: nil, content: nil)
        let result = SummaryEngine.compute(meta: meta, transactions: transactions, today: asOf)
        #expect(result.totalCents == -1000)
    }

    @Test func appliesCategoryFilter() {
        let transactions = [
            tx(date: 20260301, amount: -1000, category: "groceries"),
            tx(date: 20260302, amount: -5000, category: "rent")
        ]
        let cond = WidgetRuleCondition.makeMock(op: "is", field: "category", stringValue: "groceries")
        let meta = SummaryMeta(name: nil,
                                timeFrame: WidgetTimeFrame(start: nil, end: nil, mode: .yearToDate),
                                conditions: [cond], conditionsOp: "and", content: nil)
        let result = SummaryEngine.compute(meta: meta, transactions: transactions, today: asOf)
        #expect(result.totalCents == -1000)
    }

    @Test func transferConditionExcludesTransfers() {
        // Recreates the user's "Spent This Month" widget condition:
        // {"field":"transfer","op":"is","value":false} -> exclude transfers
        let transactions = [
            Transaction(id: "1", accountId: "a1", date: 20260501, amount: -1000,
                        payeeId: nil, payeeName: nil, categoryId: nil, categoryName: nil,
                        notes: nil, cleared: false, reconciled: false,
                        transferId: nil, isParent: false, parentId: nil,
                        tombstone: false, sortOrder: nil, importedPayee: nil),
            // This one is a transfer — should be excluded.
            Transaction(id: "2", accountId: "a1", date: 20260502, amount: -5000,
                        payeeId: nil, payeeName: nil, categoryId: nil, categoryName: nil,
                        notes: nil, cleared: false, reconciled: false,
                        transferId: "paired-tx-id", isParent: false, parentId: nil,
                        tombstone: false, sortOrder: nil, importedPayee: nil)
        ]
        // Boolean value: {"value":false}
        let cond = try! JSONDecoder().decode(WidgetRuleCondition.self, from: Data(
            #"{"op":"is","field":"transfer","value":false}"#.utf8
        ))
        let meta = SummaryMeta(name: nil, timeFrame: nil, conditions: [cond],
                                conditionsOp: "and", content: nil)
        let result = SummaryEngine.compute(meta: meta, transactions: transactions, today: asOf)
        // Only the non-transfer tx counts.
        #expect(result.totalCents == -1000)
    }

    @Test func nilMetaReturnsZero() {
        let result = SummaryEngine.compute(meta: nil, transactions: [], today: asOf)
        #expect(result.totalCents == 0)
    }

    // MARK: - Content modes (issue #15: avg widgets showed the raw sum)

    private func meta(contentType: String) -> SummaryMeta {
        SummaryMeta(
            name: nil,
            timeFrame: WidgetTimeFrame(start: nil, end: nil, mode: .yearToDate),
            conditions: nil,
            conditionsOp: nil,
            content: SummaryContent(type: contentType, divisorConditions: nil,
                                    divisorConditionsOp: nil, divisorAllTimeDateRange: nil)
        )
    }

    @Test func avgPerTransactDividesByCount() {
        let transactions = [
            tx(date: 20260301, amount: -1000),
            tx(date: 20260315, amount: -2000),
            tx(date: 20260420, amount: -600),
            tx(date: 20251201, amount: -99999)  // out of range: not counted
        ]
        let result = SummaryEngine.compute(meta: meta(contentType: "avgPerTransact"),
                                           transactions: transactions, today: asOf)
        #expect(result.totalCents == -1200)  // -3600 / 3
        #expect(result.kind == .currency)
    }

    @Test func avgPerMonthUsesFractionalMonths() {
        // asOf = 2026-05-14, YTD => Jan 1 .. May 14.
        // numMonths = 4 + 14/31 (upstream calculatePerMonth), so a -6900 total
        // averages to exactly -1550.
        let transactions = [
            tx(date: 20260110, amount: -3000),
            tx(date: 20260310, amount: -3900)
        ]
        let result = SummaryEngine.compute(meta: meta(contentType: "avgPerMonth"),
                                           transactions: transactions, today: asOf)
        #expect(result.totalCents == -1550)
    }

    @Test func avgPerMonthEmptyDataIsZero() {
        let result = SummaryEngine.compute(meta: meta(contentType: "avgPerMonth"),
                                           transactions: [], today: asOf)
        #expect(result.totalCents == 0)
    }

    @Test func percentageDividesFilteredByDivisor() {
        let groceries = WidgetRuleCondition.makeMock(op: "is", field: "category", stringValue: "groceries")
        let allSpending = WidgetRuleCondition.makeMock(op: "lt", field: "amount", intValue: 0)
        let meta = SummaryMeta(
            name: nil,
            timeFrame: WidgetTimeFrame(start: nil, end: nil, mode: .yearToDate),
            conditions: [groceries],
            conditionsOp: "and",
            content: SummaryContent(type: "percentage",
                                    divisorConditions: [allSpending],
                                    divisorConditionsOp: "and",
                                    divisorAllTimeDateRange: nil)
        )
        let transactions = [
            tx(date: 20260301, amount: -2500, category: "groceries"),
            tx(date: 20260302, amount: -7500, category: "rent")
        ]
        let result = SummaryEngine.compute(meta: meta, transactions: transactions, today: asOf)
        #expect(result.kind == .percentage)
        #expect(result.value == 25.0)
    }

    @Test func contentDecodesFromDoubleEncodedString() throws {
        // Upstream stores meta.content as a JSON *string*:
        // {"content":"{\"type\":\"avgPerMonth\"}"}
        let json = #"{"name":"Avg","content":"{\"type\":\"avgPerMonth\"}"}"#
        let meta = try JSONDecoder().decode(SummaryMeta.self, from: Data(json.utf8))
        #expect(meta.content?.type == "avgPerMonth")
    }

    @Test func contentDecodesFromInlineObject() throws {
        let json = #"{"name":"Sum","content":{"type":"sum"}}"#
        let meta = try JSONDecoder().decode(SummaryMeta.self, from: Data(json.utf8))
        #expect(meta.content?.type == "sum")
    }
}
