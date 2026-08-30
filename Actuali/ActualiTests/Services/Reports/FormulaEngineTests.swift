import Foundation
import Testing
@testable import Actuali

struct FormulaEngineTests {
    private let today = { // 2026-07-11 UTC
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: 2026, month: 7, day: 11))!
    }()

    private func tx(
        _ id: String,
        date: Int,
        amount: Int,
        isParent: Bool = false,
        parentId: String? = nil,
        tombstone: Bool = false
    ) -> Transaction {
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
        // sliding-window Apr slides to July (today's month): only July rows count.
        let transactions = [
            tx("1", date: 20260705, amount: -300_000),
            tx("2", date: 20260702, amount: 100_000),
            tx("3", date: 20260405, amount: -999_900),
        ]
        let result = FormulaEngine.compute(
            meta: meta(formula: #"=query("expenses")+query("income")"#,
                       queries: savedThisMonthQueries),
            transactions: transactions, today: today, context: .empty)
        #expect(result == .value(-2000.00))
    }

    @Test func splitChildrenAreIncludedWithoutParentDoubleCount() {
        // Reports query rows are leaf rows, so a split parent is already absent.
        // Both children should still contribute to the Formula query.
        let transactions = [
            tx("child-1", date: 20260705, amount: -6_000, parentId: "parent"),
            tx("child-2", date: 20260705, amount: -4_000, parentId: "parent"),
        ]
        let result = FormulaEngine.compute(
            meta: meta(formula: #"=query("expenses")"#, queries: savedThisMonthQueries),
            transactions: transactions, today: today, context: .empty)
        #expect(result == .value(-100.00))
    }

    @Test func uppercaseQueryAndSumMatchActualSyntax() {
        let result = FormulaEngine.compute(
            meta: meta(formula: #"=SUM(QUERY("expenses"), QUERY("income"))"#, queries: savedThisMonthQueries),
            transactions: [
                tx("1", date: 20260705, amount: -300_000),
                tx("2", date: 20260702, amount: 100_000),
            ],
            today: today,
            context: .empty)
        #expect(result == .value(-2000.00))
    }

    @Test func commonMathFunctionsAreSupported() {
        let result = FormulaEngine.compute(
            meta: meta(formula: "=ROUND(AVERAGE(1, 2, 8), 1)"),
            transactions: [], today: today, context: .empty)
        #expect(result == .value(3.7))

        let result2 = FormulaEngine.compute(
            meta: meta(formula: "=MAX(ABS(-5), SQRT(16), POWER(2, 3))"),
            transactions: [], today: today, context: .empty)
        #expect(result2 == .value(8))
    }

    @Test func ifAndComparisonsAreSupported() {
        let result = FormulaEngine.compute(
            meta: meta(formula: #"=IF(QUERY("income") > 0, QUERY("income") - QUERY("expenses"), 0)"#,
                       queries: savedThisMonthQueries),
            transactions: [
                tx("1", date: 20260705, amount: -300_000),
                tx("2", date: 20260702, amount: 100_000),
            ],
            today: today,
            context: .empty)
        // 1000 - (-3000) = 4000.
        #expect(result == .value(4000.00))
    }

    @Test func minProductCountFloorCeilingAndPiAreSupported() {
        let result = FormulaEngine.compute(
            meta: meta(formula: "=MIN(8, 2, 5) + PRODUCT(2, 3) + COUNT(1, 2, 3)"),
            transactions: [], today: today, context: .empty)
        #expect(result == .value(11))

        let result2 = FormulaEngine.compute(
            meta: meta(formula: "=FLOOR(10.8, 1) + CEILING(10.2, 1)"),
            transactions: [], today: today, context: .empty)
        #expect(result2 == .value(22))

        let result3 = FormulaEngine.compute(
            meta: meta(formula: "=PI()"),
            transactions: [], today: today, context: .empty)
        guard case .value(let value) = result3 else {
            Issue.record("expected PI() to return a value, got \(result3)")
            return
        }
        #expect(abs(value - Double.pi) < 0.0000001)
    }

    @Test func logicalFunctionsAreSupported() {
        let result = FormulaEngine.compute(
            meta: meta(formula: "=IF(AND(1=1, 2=2), OR(0, 1), 0)"),
            transactions: [], today: today, context: .empty)
        #expect(result == .value(1))

        let result2 = FormulaEngine.compute(
            meta: meta(formula: "=NOT(1=1)"),
            transactions: [], today: today, context: .empty)
        #expect(result2 == .value(0))
    }

    @Test func queryCountIsSupportedAndUsesTimeFrame() {
        let result = FormulaEngine.compute(
            meta: meta(formula: #"=QUERY_COUNT("expenses")"#, queries: savedThisMonthQueries),
            transactions: [
                tx("1", date: 20260705, amount: -300_000),
                tx("2", date: 20260702, amount: -50_000),
                tx("3", date: 20260703, amount: 100_000),
                tx("4", date: 20260403, amount: -10_000),
            ],
            today: today,
            context: .empty)
        #expect(result == .value(2))
    }

    @Test func invalidFunctionIsUnsupported() {
        let result = FormulaEngine.compute(
            meta: meta(formula: "=DOES_NOT_EXIST(1)"),
            transactions: [], today: today, context: .empty)
        guard case .unsupported = result else {
            Issue.record("expected unsupported function")
            return
        }
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
            Issue.record("expected .unsupported, got \(result)"); return
        }
    }

    @Test func functionsBeyondSupportedSubsetAreUnsupported() {
        let result = FormulaEngine.compute(
            meta: meta(formula: #"=BUDGET_QUERY("spent", "all", "2026-01", "2026-07")"#),
            transactions: [], today: today, context: .empty)
        guard case .unsupported = result else {
            Issue.record("expected .unsupported, got \(result)"); return
        }
    }

    @Test func unknownQueryNameCountsAsZero() {
        let result = FormulaEngine.compute(
            meta: meta(formula: #"=QUERY("nope")+5"#),
            transactions: [], today: today, context: .empty)
        #expect(result == .value(5))
    }

    @Test func subtractionIsLeftAssociative() {
        let result = FormulaEngine.compute(
            meta: meta(formula: "=10-2-3"), transactions: [], today: today, context: .empty)
        #expect(result == .value(5))
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
        "=",            // empty expression
        "=QUERY(",      // missing argument
        "=1.2.3",       // malformed number
        "=1 2",         // trailing garbage
        "=(1+2",        // unclosed paren
        #"=QUERY("a"#,  // unclosed quote
        "=SUM(1 2)",    // missing comma between arguments
    ])
    func malformedFormulasAreUnsupported(formula: String) {
        let result = FormulaEngine.compute(
            meta: meta(formula: formula), transactions: [], today: today, context: .empty)
        guard case .unsupported = result else {
            Issue.record("expected .unsupported for \(formula), got \(result)"); return
        }
    }
}
