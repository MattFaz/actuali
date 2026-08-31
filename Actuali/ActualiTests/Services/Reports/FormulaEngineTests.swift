import Foundation
import Testing
@testable import Actuali

struct FormulaEngineTests {
    private let today = { // 2026-07-11 UTC
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: 2026, month: 7, day: 11))!
    }()

    private func tx(_ id: String, date: Int, amount: Int,
                    isParent: Bool = false, parentId: String? = nil, tombstone: Bool = false) -> Transaction {
        Transaction(id: id, accountId: "a1", date: date, amount: amount,
                    payeeId: nil, payeeName: nil, categoryId: nil, categoryName: nil,
                    notes: nil, cleared: true, reconciled: false, transferId: nil,
                    isParent: isParent, parentId: parentId, tombstone: tombstone,
                    sortOrder: nil, importedPayee: nil)
    }

    private func meta(formula: String, queries: [String: FormulaQueryMeta] = [:]) -> FormulaMeta {
        FormulaMeta(name: "Test", formula: formula, queries: queries)
    }

    private var savedThisMonthQueries: [String: FormulaQueryMeta] {
        let window = WidgetTimeFrame(start: "2026-04-01", end: "2026-04-30", mode: .slidingWindow)
        return [
            "expenses": FormulaQueryMeta(
                conditions: [WidgetRuleCondition(op: "lt", field: "amount",
                    value: AnyCodable(rawJSON: Data("0".utf8)), options: nil, customName: nil)],
                conditionsOp: "and", timeFrame: window),
            "income": FormulaQueryMeta(
                conditions: [WidgetRuleCondition(op: "gt", field: "amount",
                    value: AnyCodable(rawJSON: Data("0".utf8)), options: nil, customName: nil)],
                conditionsOp: "and", timeFrame: window),
        ]
    }

    @Test func sumsQueriesOverSlidingWindow() {
        let result = FormulaEngine.compute(
            meta: meta(formula: #"=QUERY("expenses")+QUERY("income")"#, queries: savedThisMonthQueries),
            transactions: [
                tx("1", date: 20260705, amount: -300_000),
                tx("2", date: 20260702, amount: 100_000),
                tx("3", date: 20260405, amount: -999_900),
            ], today: today, context: .empty)
        #expect(result == .value(-2000.00))
    }

    @Test func splitParentsAndTombstonesAreExcluded() {
        let result = FormulaEngine.compute(
            meta: meta(formula: #"=QUERY("expenses")"#, queries: savedThisMonthQueries),
            transactions: [
                tx("parent", date: 20260705, amount: -10_000, isParent: true),
                tx("child-1", date: 20260705, amount: -6_000, parentId: "parent"),
                tx("child-2", date: 20260705, amount: -4_000, parentId: "parent"),
                tx("deleted", date: 20260705, amount: -500, tombstone: true),
            ], today: today, context: .empty)
        #expect(result == .value(-100.00))
    }

    @Test func ifAndComparisonsAreSupported() {
        let result = FormulaEngine.compute(
            meta: meta(formula: #"=IF(QUERY("income") > 0, QUERY("income") - QUERY("expenses"), 0)"#, queries: savedThisMonthQueries),
            transactions: [
                tx("1", date: 20260705, amount: -300_000),
                tx("2", date: 20260702, amount: 100_000),
            ], today: today, context: .empty)
        #expect(result == .value(4000.00))

        let comparison = FormulaEngine.compute(
            meta: meta(formula: "=5 > 3"), transactions: [], today: today, context: .empty)
        #expect(comparison == .number(1))
    }

    @Test func supportedFunctionsPreserveUnits() {
        let sum = FormulaEngine.compute(
            meta: meta(formula: #"=SUM(QUERY("expenses"), QUERY("income"))"#, queries: savedThisMonthQueries),
            transactions: [
                tx("1", date: 20260705, amount: -300_000),
                tx("2", date: 20260702, amount: 100_000),
            ], today: today, context: .empty)
        #expect(sum == .value(-2000.00))

        let minMax = FormulaEngine.compute(
            meta: meta(formula: "=MAX(MIN(8, 2, 5), ABS(-6))"),
            transactions: [], today: today, context: .empty)
        #expect(minMax == .number(6))

        let queryOverLiteral = FormulaEngine.compute(
            meta: meta(formula: #"=QUERY("expenses") / 12"#, queries: savedThisMonthQueries),
            transactions: [
                tx("1", date: 20260705, amount: -300_000),
            ], today: today, context: .empty)
        #expect(queryOverLiteral == .value(-250.00))

        let currencyRatio = FormulaEngine.compute(
            meta: meta(formula: #"=QUERY("expenses") / QUERY("income")"#, queries: savedThisMonthQueries),
            transactions: [
                tx("expense", date: 20260705, amount: -10_000),
                tx("income", date: 20260705, amount: 20_000),
            ], today: today, context: .empty)
        #expect(currencyRatio == .number(-0.5))
    }

    @Test func subtractionIsLeftAssociative() {
        let result = FormulaEngine.compute(
            meta: meta(formula: "=10-2-3"), transactions: [], today: today, context: .empty)
        #expect(result == .number(5))
    }

    @Test func honorsPrecedenceAndParens() {
        let result = FormulaEngine.compute(
            meta: meta(formula: "=2+3*4"), transactions: [], today: today, context: .empty)
        #expect(result == .number(14))

        let result2 = FormulaEngine.compute(
            meta: meta(formula: "=(2+3)*-4"), transactions: [], today: today, context: .empty)
        #expect(result2 == .number(-20))
    }

    @Test func extremeCurrencyResultsAreUnsupportedBeforeDisplayConversion() {
        let result = FormulaEngine.compute(
            meta: meta(formula: #"=QUERY("income") * 1000000000000000000"#, queries: savedThisMonthQueries),
            transactions: [
                tx("income", date: 20260705, amount: 100),
            ], today: today, context: .empty)
        guard case .unsupported = result else {
            Issue.record("expected currency overflow to be unsupported, got \(result)")
            return
        }
    }

    @Test func unknownFunctionsAndEmptySumAreUnsupported() {
        for formula in ["=SUM()", "=QUERY_COUNT(\"expenses\")", "=POWER(2, 3)"] {
            let result = FormulaEngine.compute(
                meta: meta(formula: formula), transactions: [], today: today, context: .empty)
            guard case .unsupported = result else {
                Issue.record("expected unsupported for \(formula), got \(result)")
                return
            }
        }
    }

    @Test func unknownQueryNameCountsAsZero() {
        let result = FormulaEngine.compute(
            meta: meta(formula: #"=QUERY("nope")+5"#), transactions: [], today: today, context: .empty)
        #expect(result == .value(5))
    }

    @Test func decimalLiteralsParse() {
        let bareDot = FormulaEngine.compute(
            meta: meta(formula: "=.5+1.25"), transactions: [], today: today, context: .empty)
        #expect(bareDot == .number(1.75))

        let standard = FormulaEngine.compute(
            meta: meta(formula: "=0.5+1.25"), transactions: [], today: today, context: .empty)
        #expect(standard == .number(1.75))
    }

    @Test(arguments: [
        "=", "=QUERY(", "=1.2.3", "=1 2", "=(1+2", #"=QUERY("a"#, "=SUM(1 2)"
    ])
    func malformedFormulasAreUnsupported(formula: String) {
        let result = FormulaEngine.compute(
            meta: meta(formula: formula), transactions: [], today: today, context: .empty)
        guard case .unsupported = result else {
            Issue.record("expected unsupported for \(formula), got \(result)")
            return
        }
    }
}
