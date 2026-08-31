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

    @Test func sumsTwoQueriesOverSlidingWindow() {
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

    @Test func uppercaseQueryAndSumMatchActualSyntax() {
        let result = FormulaEngine.compute(
            meta: meta(formula: #"=SUM(QUERY("expenses"), QUERY("income"))"#, queries: savedThisMonthQueries),
            transactions: [
                tx("1", date: 20260705, amount: -300_000),
                tx("2", date: 20260702, amount: 100_000),
            ], today: today, context: .empty)
        #expect(result == .value(-2000.00))
    }

    @Test func ifAndComparisonsAreSupported() {
        let result = FormulaEngine.compute(
            meta: meta(formula: #"=IF(QUERY("income") > 0, QUERY("income") - QUERY("expenses"), 0)"#, queries: savedThisMonthQueries),
            transactions: [
                tx("1", date: 20260705, amount: -300_000),
                tx("2", date: 20260702, amount: 100_000),
            ], today: today, context: .empty)
        #expect(result == .value(4000.00))
    }

    @Test func commonFunctionsAreSupported() {
        let average = FormulaEngine.compute(
            meta: meta(formula: "=ROUND(AVERAGE(1, 2, 8), 1)"),
            transactions: [], today: today, context: .empty)
        #expect(average == .value(3.7))

        let minMax = FormulaEngine.compute(
            meta: meta(formula: "=MAX(MIN(8, 2, 5), PRODUCT(2, 3))"),
            transactions: [], today: today, context: .empty)
        #expect(minMax == .value(6))

        let math = FormulaEngine.compute(
            meta: meta(formula: "=ABS(-5) + SQRT(16) + POWER(2, 3)"),
            transactions: [], today: today, context: .empty)
        #expect(math == .value(17))

        let rounded = FormulaEngine.compute(
            meta: meta(formula: "=FLOOR(10.8, 1) + CEILING(10.2, 1)"),
            transactions: [], today: today, context: .empty)
        #expect(rounded == .value(21))
    }

    @Test func logicalAndCountFunctionsAreSupported() {
        let logical = FormulaEngine.compute(
            meta: meta(formula: "=IF(AND(1=1, 2=2), OR(0, 1), 0)"),
            transactions: [], today: today, context: .empty)
        #expect(logical == .number(1))

        let not = FormulaEngine.compute(
            meta: meta(formula: "=NOT(1=1)"),
            transactions: [], today: today, context: .empty)
        #expect(not == .number(0))

        let count = FormulaEngine.compute(
            meta: meta(formula: #"=QUERY_COUNT("expenses")"#, queries: savedThisMonthQueries),
            transactions: [
                tx("1", date: 20260705, amount: -300_000),
                tx("2", date: 20260702, amount: -50_000),
                tx("3", date: 20260403, amount: -10_000),
            ], today: today, context: .empty)
        #expect(count == .number(2))

        let pi = FormulaEngine.compute(
            meta: meta(formula: "=PI()"),
            transactions: [], today: today, context: .empty)
        guard case .number(let value) = pi else {
            Issue.record("expected PI() to return a plain number, got \(pi)")
            return
        }
        #expect(abs(value - Double.pi) < 0.0000001)
    }

    @Test func currencyDivisionProducesPlainNumber() {
        let result = FormulaEngine.compute(
            meta: meta(formula: #"=QUERY("expenses") / QUERY("income")"#, queries: savedThisMonthQueries),
            transactions: [
                tx("expense", date: 20260705, amount: -10_000),
                tx("income", date: 20260705, amount: 20_000),
            ], today: today, context: .empty)
        #expect(result == .number(-0.5))
    }

    @Test func extremeResultsAreUnsupportedBeforeDisplayConversion() {
        let plainNumber = FormulaEngine.compute(
            meta: meta(formula: "=POWER(10, 30)"), transactions: [], today: today, context: .empty)
        #expect(plainNumber == .number(1e30))

        let currencyOverflow = FormulaEngine.compute(
            meta: meta(formula: "=SUM(QUERY(\"income\"), POWER(10, 30))", queries: savedThisMonthQueries),
            transactions: [
                tx("income", date: 20260705, amount: 100),
            ], today: today, context: .empty)
        guard case .unsupported = currencyOverflow else {
            Issue.record("expected currency overflow to be unsupported, got \(currencyOverflow)")
            return
        }
    }

    @Test func roundRejectsInvalidDigitArguments() {
        for formula in ["=ROUND(1, POWER(10, 30))", "=ROUND(1, SQRT(0-1))"] {
            let result = FormulaEngine.compute(
                meta: meta(formula: formula), transactions: [], today: today, context: .empty)
            guard case .unsupported = result else {
                Issue.record("expected unsupported for \(formula), got \(result)")
                return
            }
        }
    }

    @Test func dashboardIdentityCannotCollideOnDelimiterCharacters() {
        let first = ReportsTabView.dashboardIdentity(pageId: "p", widgetIds: ["a", "b|c"])
        let second = ReportsTabView.dashboardIdentity(pageId: "p|a", widgetIds: ["b", "c"])
        #expect(first != second)
    }

    @Test func emptySumAndUnsupportedFunctionsAreRejected() {
        for formula in ["=SUM()", "=BUDGET_QUERY(\"spent\", \"all\", \"2026-01\", \"2026-07\")"] {
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

    @Test func honorsPrecedenceAndParens() {
        let result = FormulaEngine.compute(
            meta: meta(formula: "=2+3*4"), transactions: [], today: today, context: .empty)
        #expect(result == .value(14))
        let result2 = FormulaEngine.compute(
            meta: meta(formula: "=(2+3)*-4"), transactions: [], today: today, context: .empty)
        #expect(result2 == .value(-20))
    }

    @Test func divisionByZeroIsUnsupported() {
        let result = FormulaEngine.compute(
            meta: meta(formula: "=1/0"), transactions: [], today: today, context: .empty)
        guard case .unsupported = result else {
            Issue.record("expected .unsupported, got \(result)")
            return
        }
    }

    @Test func decimalLiteralsParse() {
        let bareDot = FormulaEngine.compute(
            meta: meta(formula: "=.5+1.25"), transactions: [], today: today, context: .empty)
        #expect(bareDot == .value(1.75))
        let standard = FormulaEngine.compute(
            meta: meta(formula: "=0.5+1.25"), transactions: [], today: today, context: .empty)
        #expect(standard == .value(1.75))
    }

    @Test(arguments: [
        "=", "=QUERY(", "=1.2.3", "=1 2", "=(1+2", #"=QUERY("a"#, "=SUM(1 2)"
    ])
    func malformedFormulasAreUnsupported(formula: String) {
        let result = FormulaEngine.compute(
            meta: meta(formula: formula), transactions: [], today: today, context: .empty)
        guard case .unsupported = result else {
            Issue.record("expected .unsupported for \(formula), got \(result)")
            return
        }
    }
}
