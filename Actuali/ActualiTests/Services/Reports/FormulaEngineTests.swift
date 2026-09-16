import Foundation
import Testing
@testable import Actuali

struct FormulaEngineTests {
    private let today = { // 2026-07-11 UTC
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: 2026, month: 7, day: 11))!
    }()

    private func tx(_ id: String, date: Int, amount: Int) -> Transaction {
        Transaction(id: id, accountId: "a1", date: date, amount: amount,
                    payeeId: nil, payeeName: nil, categoryId: nil, categoryName: nil,
                    notes: nil, cleared: true, reconciled: false, transferId: nil,
                    isParent: false, parentId: nil, tombstone: false,
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
            tx("1", date: 20260705, amount: -300_000),  // -3000.00 expense, in window
            tx("2", date: 20260702, amount: 100_000),   // +1000.00 income, in window
            tx("3", date: 20260405, amount: -999_900),  // April: outside slid window
        ]
        let result = FormulaEngine.compute(
            meta: meta(formula: #"=query("expenses")+query("income")"#,
                       queries: savedThisMonthQueries),
            transactions: transactions, today: today, context: .empty)
        #expect(result == .value(-2000.00))
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

    @Test func evaluatesBasicFormulaCardFunctionsAndText() {
        let transactions = [
            tx("expense", date: 20260705, amount: -25_000),
            tx("income", date: 20260702, amount: 100_000),
        ]
        let formula = #"=IF(QUERY("income")=0,0,ROUND(1-(ABS(QUERY("expenses"))/QUERY("income")),4)*100)&"%""#

        let result = FormulaEngine.compute(
            meta: meta(formula: formula, queries: savedThisMonthQueries),
            transactions: transactions, today: today, context: .empty)

        #expect(result == .text("75%"))
    }

    @Test func comparisonResultRendersAsBoolean() {
        let result = FormulaEngine.compute(
            meta: meta(formula: #"=1>2"#), transactions: [], today: today, context: .empty)
        #expect(result == .text("FALSE"))
    }

    @Test func comparisonOperatorsEvaluate() {
        let cases = [
            (#"=2=2"#, "TRUE"),
            (#"=2<>3"#, "TRUE"),
            (#"=3>2"#, "TRUE"),
            (#"=2<3"#, "TRUE"),
            (#"=2>=2"#, "TRUE"),
            (#"=2<=2"#, "TRUE"),
        ]

        for (formula, expected) in cases {
            let result = FormulaEngine.compute(
                meta: meta(formula: formula), transactions: [], today: today, context: .empty)
            #expect(result == .text(expected))
        }
    }

    @Test func textComparisonUsesHyperFormulaCollation() {
        let formulas = [#"="a"<"b""#, #"="Income"="income""#, #"="résumé"="resume""#]
        for formula in formulas {
            let result = FormulaEngine.compute(
                meta: meta(formula: formula), transactions: [], today: today, context: .empty)
            #expect(result == .text("TRUE"))
        }
    }

    @Test func ifUsesHyperFormulaTruthiness() {
        let formulas = [#"=IF("FALSE",1,2)"#, "=IF(0.0000000000000001,1,2)"]
        let expected: [FormulaEngine.Result] = [.value(2), .value(1)]
        for (formula, expected) in zip(formulas, expected) {
            let result = FormulaEngine.compute(
                meta: meta(formula: formula), transactions: [], today: today, context: .empty)
            #expect(result == expected)
        }
    }

    @Test func roundSupportsDefaultAndNegativeDigitCounts() {
        let defaultDigits = FormulaEngine.compute(
            meta: meta(formula: "=ROUND(2.5)"), transactions: [], today: today, context: .empty)
        #expect(defaultDigits == .value(3))

        let negativeDigits = FormulaEngine.compute(
            meta: meta(formula: "=ROUND(123.456,-2)"), transactions: [], today: today, context: .empty)
        #expect(negativeDigits == .value(100))
    }

    @Test func concatenationBindsTighterThanComparison() {
        let result = FormulaEngine.compute(
            meta: meta(formula: #"="a"&"b"="ab""#),
            transactions: [], today: today, context: .empty)
        #expect(result == .text("TRUE"))
    }

    @Test func concatenationUsesNumberConversionAndAbs() {
        let result = FormulaEngine.compute(
            meta: meta(formula: #"="Balance: "&ABS(-12.5)"#),
            transactions: [], today: today, context: .empty)
        #expect(result == .text("Balance: 12.5"))
    }

    @Test func nonFiniteResultsAreUnsupported() {
        for formula in ["=ROUND(1,400)", #"=ROUND(1,400)&"%""#, #"=ROUND(1,400)="""#] {
            let result = FormulaEngine.compute(
                meta: meta(formula: formula), transactions: [], today: today, context: .empty)
            guard case .unsupported = result else {
                Issue.record("expected .unsupported, got \(result)")
                continue
            }
        }
    }

    @Test func functionsOutsideSupportedFormulaSubsetAreUnsupported() {
        let result = FormulaEngine.compute(
            meta: meta(formula: #"=SUM(query("a"))"#),
            transactions: [], today: today, context: .empty)
        guard case .unsupported = result else {
            Issue.record("expected .unsupported, got \(result)"); return
        }
    }

    @Test func unknownQueryNameCountsAsZero() {
        let result = FormulaEngine.compute(
            meta: meta(formula: #"=query("nope")+5"#),
            transactions: [], today: today, context: .empty)
        #expect(result == .value(5))
    }

    @Test func subtractionIsLeftAssociative() {
        let result = FormulaEngine.compute(
            meta: meta(formula: "=10-2-3"), transactions: [], today: today, context: .empty)
        #expect(result == .value(5))
    }

    @Test func decimalLiteralsParse() {
        // Bare leading-dot decimals (".5") and standard decimals both parse.
        let bareDot = FormulaEngine.compute(
            meta: meta(formula: "=.5+1.25"), transactions: [], today: today, context: .empty)
        #expect(bareDot == .value(1.75))
        let standard = FormulaEngine.compute(
            meta: meta(formula: "=0.5+1.25"), transactions: [], today: today, context: .empty)
        #expect(standard == .value(1.75))
    }

    @Test(arguments: [
        "=",            // empty expression
        "=query(",      // missing argument
        "=1.2.3",       // malformed number
        "=1 2",         // trailing garbage
        "=(1+2",        // unclosed paren
        #"=query("a"#,  // unclosed quote
    ])
    func malformedFormulasAreUnsupported(formula: String) {
        let result = FormulaEngine.compute(
            meta: meta(formula: formula), transactions: [], today: today, context: .empty)
        guard case .unsupported = result else {
            Issue.record("expected .unsupported for \(formula), got \(result)"); return
        }
    }
}
