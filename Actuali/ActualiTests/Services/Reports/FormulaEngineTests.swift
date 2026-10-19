import Foundation
import Testing
@testable import Actuali

struct FormulaEngineTests {
    private let today = { // 2026-07-11 UTC
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: 2026, month: 7, day: 11))!
    }()

    private func tx(_ id: String, date: Int, amount: Int, tombstone: Bool = false) -> Transaction {
        Transaction(id: id, accountId: "a1", date: date, amount: amount,
                    payeeId: nil, payeeName: nil, categoryId: nil, categoryName: nil,
                    notes: nil, cleared: true, reconciled: false, transferId: nil,
                    isParent: false, parentId: nil, tombstone: tombstone,
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
                conditionsOp: "and", timeFrame: window
            ),
            "income": FormulaQueryMeta(
                conditions: [WidgetRuleCondition(op: "gt", field: "amount",
                                                 value: AnyCodable(rawJSON: Data("0".utf8)), options: nil, customName: nil)],
                conditionsOp: "and", timeFrame: window
            ),
        ]
    }

    @Test func sumsTwoQueriesOverSlidingWindow() {
        // sliding-window Apr slides to July (today's month): only July rows count.
        let transactions = [
            tx("1", date: 20_260_705, amount: -300_000), // -3000.00 expense, in window
            tx("2", date: 20_260_702, amount: 100_000), // +1000.00 income, in window
            tx("3", date: 20_260_405, amount: -999_900), // April: outside slid window
        ]
        let result = FormulaEngine.compute(
            meta: meta(formula: #"=query("expenses")+query("income")"#,
                       queries: savedThisMonthQueries),
            transactions: transactions, today: today, context: .empty
        )
        #expect(result == .value(-2000.00))
    }

    @Test func queryCountUsesQueryFiltersAndIgnoresTombstones() {
        let transactions = [
            tx("expense1", date: 20_260_705, amount: -25000),
            tx("expense2", date: 20_260_706, amount: -5000),
            tx("income", date: 20_260_702, amount: 100_000),
            tx("deleted", date: 20_260_706, amount: -1000, tombstone: true),
            tx("old-expense", date: 20_260_405, amount: -5000),
        ]
        let result = FormulaEngine.compute(
            meta: meta(formula: #"=QUERY_COUNT("expenses")"#, queries: savedThisMonthQueries),
            transactions: transactions, today: today, context: .empty
        )
        #expect(result == .plain(2))
    }

    @Test func amountsDividedOrMultipliedByCountsStayCurrency() {
        let transactions = [
            tx("expense1", date: 20_260_705, amount: -25000),
            tx("expense2", date: 20_260_706, amount: -5000),
        ]
        let cases: [(String, FormulaEngine.Result)] = [
            (#"=QUERY("expenses")/QUERY_COUNT("expenses")"#, .value(-150)),
            (#"=QUERY_COUNT("expenses")*QUERY("expenses")"#, .value(-600)),
            (#"=QUERY_COUNT("expenses")/QUERY_COUNT("expenses")"#, .plain(1)),
            (#"=QUERY_COUNT("expenses")+1"#, .plain(3)),
        ]
        for (formula, expected) in cases {
            let result = FormulaEngine.compute(
                meta: meta(formula: formula, queries: savedThisMonthQueries),
                transactions: transactions, today: today, context: .empty
            )
            #expect(result == expected, "\(formula)")
        }
    }

    @Test func unknownQueryCountIsZero() {
        let result = FormulaEngine.compute(
            meta: meta(formula: #"=QUERY_COUNT("missing")"#),
            transactions: [], today: today, context: .empty
        )
        #expect(result == .plain(0))
    }

    @Test func honorsPrecedenceAndParens() {
        let result = FormulaEngine.compute(
            meta: meta(formula: "=2+3*4"), transactions: [], today: today, context: .empty
        )
        #expect(result == .value(14))
        let result2 = FormulaEngine.compute(
            meta: meta(formula: "=(2+3)*-4"), transactions: [], today: today, context: .empty
        )
        #expect(result2 == .value(-20))
    }

    @Test func exponentAndPercentageOperatorsUseHyperFormulaPrecedence() {
        let cases: [(String, Double)] = [
            ("=2^3^2", 64),
            ("=-2^2", 4),
            ("=2^-2", 0.25),
            ("=25%*200", 50),
            ("=200*25%", 50),
        ]
        for (formula, expected) in cases {
            let result = FormulaEngine.compute(
                meta: meta(formula: formula), transactions: [], today: today, context: .empty
            )
            #expect(result == .value(expected))
        }
    }

    @Test func divisionByZeroIsUnsupported() {
        let result = FormulaEngine.compute(
            meta: meta(formula: "=1/0"), transactions: [], today: today, context: .empty
        )
        guard case .unsupported = result else {
            Issue.record("expected .unsupported, got \(result)"); return
        }
    }

    @Test func tinyDivisorsDivideInsteadOfReportingDivisionByZero() {
        let result = FormulaEngine.compute(
            meta: meta(formula: "=1/0.0000000000000001"),
            transactions: [], today: today, context: .empty
        )
        #expect(result == .value(1e16))
    }

    @Test func evaluatesBasicFormulaCardFunctionsAndText() {
        let transactions = [
            tx("expense", date: 20_260_705, amount: -25000),
            tx("income", date: 20_260_702, amount: 100_000),
        ]
        let formula = #"=IF(QUERY("income")=0,0,ROUND(1-(ABS(QUERY("expenses"))/QUERY("income")),4)*100)&"%""#

        let result = FormulaEngine.compute(
            meta: meta(formula: formula, queries: savedThisMonthQueries),
            transactions: transactions, today: today, context: .empty
        )

        #expect(result == .text("75%"))
    }

    @Test func comparisonResultRendersAsBoolean() {
        let result = FormulaEngine.compute(
            meta: meta(formula: #"=1>2"#), transactions: [], today: today, context: .empty
        )
        #expect(result == .text("FALSE"))
    }

    @Test(arguments: [
        (#"=2=2"#, "TRUE"),
        (#"=2<>3"#, "TRUE"),
        (#"=3>2"#, "TRUE"),
        (#"=2<3"#, "TRUE"),
        (#"=2>=2"#, "TRUE"),
        (#"=2<=2"#, "TRUE"),
    ])
    func comparisonOperatorsEvaluate(formula: String, expected: String) {
        let result = FormulaEngine.compute(
            meta: meta(formula: formula), transactions: [], today: today, context: .empty
        )
        #expect(result == .text(expected))
    }

    @Test func textComparisonUsesHyperFormulaCollation() {
        let formulas = [#"="a"<"b""#, #"="Income"="income""#, #"="résumé"="resume""#]
        for formula in formulas {
            let result = FormulaEngine.compute(
                meta: meta(formula: formula), transactions: [], today: today, context: .empty
            )
            #expect(result == .text("TRUE"))
        }
    }

    @Test func ifUsesHyperFormulaTruthiness() {
        let formulas = [#"=IF("FALSE",1,2)"#, "=IF(0.0000000000000001,1,2)"]
        let expected: [FormulaEngine.Result] = [.value(2), .value(1)]
        for (formula, expected) in zip(formulas, expected) {
            let result = FormulaEngine.compute(
                meta: meta(formula: formula), transactions: [], today: today, context: .empty
            )
            #expect(result == expected)
        }
    }

    @Test func logicalFunctionsAndBooleanLiteralsEvaluate() {
        let cases: [(String, FormulaEngine.Result)] = [
            (#"=IF(AND(TRUE(),NOT(FALSE())),SUM(1,2,3),0)"#, .value(6)),
            ("=IF(OR(FALSE(),0,1),7,8)", .value(7)),
            (#"=NOT("FALSE")"#, .text("TRUE")),
            ("=TRUE()", .text("TRUE")),
            ("=FALSE()", .text("FALSE")),
        ]
        for (formula, expected) in cases {
            let result = FormulaEngine.compute(
                meta: meta(formula: formula), transactions: [], today: today, context: .empty
            )
            #expect(result == expected)
        }
    }

    @Test func scalarAggregationFunctionsEvaluate() {
        let cases: [(String, Double)] = [
            ("=SUM(1,2,3)", 6),
            ("=MIN(4,1,2)", 1),
            ("=MAX(4,1,2)", 4),
            ("=AVERAGE(1,2,3,4)", 2.5),
            ("=PRODUCT(2,3,4)", 24),
            (#"=SUM(QUERY("missing"),ABS(-5))"#, 5),
        ]
        for (formula, expected) in cases {
            let result = FormulaEngine.compute(
                meta: meta(formula: formula), transactions: [], today: today, context: .empty
            )
            #expect(result == .value(expected))
        }
    }

    @Test func roundingAndAdditionalMathFunctionsEvaluate() {
        let cases: [(String, Double)] = [
            ("=ROUNDUP(1.231,2)", 1.24),
            ("=ROUNDUP(-1.231,2)", -1.24),
            ("=ROUNDUP(0.07,2)", 0.07),
            ("=ROUNDDOWN(-1.239,2)", -1.23),
            ("=ROUNDDOWN(0.29,2)", 0.29),
            ("=TRUNC(123.456,1)", 123.4),
            ("=TRUNC(-123.456,-1)", -120),
            ("=TRUNC(0.29,2)", 0.29),
            ("=MOD(-3,2)", 1),
            ("=POWER(2,8)", 256),
            ("=SQRT(81)", 9),
        ]
        for (formula, expected) in cases {
            let result = FormulaEngine.compute(
                meta: meta(formula: formula), transactions: [], today: today, context: .empty
            )
            #expect(result == .value(expected))
        }
    }

    @Test func ifErrorReturnsFallbackOnlyWhenEvaluationFails() {
        let cases: [(String, FormulaEngine.Result)] = [
            ("=IFERROR(1/0,42)", .value(42)),
            ("=IFERROR(SQRT(-1),7)", .value(7)),
            (#"=IFERROR("ok","fallback")"#, .text("ok")),
            ("=IFERROR(1,1/0)", .value(1)),
            // AND/OR evaluate every argument before deciding, as HyperFormula does.
            ("=IFERROR(AND(FALSE(),1/0),5)", .value(5)),
            ("=IFERROR(OR(TRUE(),1/0),5)", .value(5)),
        ]
        for (formula, expected) in cases {
            let result = FormulaEngine.compute(
                meta: meta(formula: formula), transactions: [], today: today, context: .empty
            )
            #expect(result == expected)
        }
    }

    @Test func roundSupportsDefaultAndNegativeDigitCounts() {
        let defaultDigits = FormulaEngine.compute(
            meta: meta(formula: "=ROUND(2.5)"), transactions: [], today: today, context: .empty
        )
        #expect(defaultDigits == .value(3))

        let negativeDigits = FormulaEngine.compute(
            meta: meta(formula: "=ROUND(123.456,-2)"), transactions: [], today: today, context: .empty
        )
        #expect(negativeDigits == .value(100))
    }

    @Test func concatenationBindsTighterThanComparison() {
        let result = FormulaEngine.compute(
            meta: meta(formula: #"="a"&"b"="ab""#),
            transactions: [], today: today, context: .empty
        )
        #expect(result == .text("TRUE"))
    }

    @Test func stringLiteralsSupportEscapedDoubleQuotes() {
        let result = FormulaEngine.compute(
            meta: meta(formula: #"="He said ""Hi""""#),
            transactions: [], today: today, context: .empty
        )
        #expect(result == .text("He said \"Hi\""))
    }

    @Test func concatenationUsesNumberConversionAndAbs() {
        let result = FormulaEngine.compute(
            meta: meta(formula: #"="Balance: "&ABS(-12.5)"#),
            transactions: [], today: today, context: .empty
        )
        #expect(result == .text("Balance: 12.5"))
    }

    @Test(arguments: ["=ROUND(1,400)", #"=ROUND(1,400)&"%""#, #"=ROUND(1,400)="""#, "=SQRT(-1)"])
    func nonFiniteResultsAreUnsupported(formula: String) {
        let result = FormulaEngine.compute(
            meta: meta(formula: formula), transactions: [], today: today, context: .empty
        )
        guard case .unsupported = result else {
            Issue.record("expected .unsupported, got \(result)"); return
        }
    }

    @Test func functionsOutsideSupportedFormulaSubsetAreUnsupported() {
        let formulas = ["=MEDIAN(1,2,3)", "=IFERROR(MEDIAN(1,2,3),0)", "=AND(FALSE(),MEDIAN(1))", "=OR(TRUE(),MEDIAN(1))"]
        for formula in formulas {
            let result = FormulaEngine.compute(
                meta: meta(formula: formula), transactions: [], today: today, context: .empty
            )
            guard case .unsupported = result else {
                Issue.record("expected .unsupported, got \(result)")
                return
            }
        }
    }

    @Test func unknownQueryNameCountsAsZero() {
        let result = FormulaEngine.compute(
            meta: meta(formula: #"=query("nope")+5"#),
            transactions: [], today: today, context: .empty
        )
        #expect(result == .value(5))
    }

    @Test func subtractionIsLeftAssociative() {
        let result = FormulaEngine.compute(
            meta: meta(formula: "=10-2-3"), transactions: [], today: today, context: .empty
        )
        #expect(result == .value(5))
    }

    @Test func decimalLiteralsParse() {
        // Bare leading-dot decimals (".5") and standard decimals both parse.
        let bareDot = FormulaEngine.compute(
            meta: meta(formula: "=.5+1.25"), transactions: [], today: today, context: .empty
        )
        #expect(bareDot == .value(1.75))
        let standard = FormulaEngine.compute(
            meta: meta(formula: "=0.5+1.25"), transactions: [], today: today, context: .empty
        )
        #expect(standard == .value(1.75))
    }

    @Test(arguments: [
        "=", // empty expression
        "=query(", // missing argument
        "=1.2.3", // malformed number
        "=1 2", // trailing garbage
        "=(1+2", // unclosed paren
        #"=query("a"#, // unclosed quote
        "=2^", // missing exponent
        "=25%abc(1)", // trailing garbage after percentage
    ])
    func malformedFormulasAreUnsupported(formula: String) {
        let result = FormulaEngine.compute(
            meta: meta(formula: formula), transactions: [], today: today, context: .empty
        )
        guard case .unsupported = result else {
            Issue.record("expected .unsupported for \(formula), got \(result)"); return
        }
    }
}
