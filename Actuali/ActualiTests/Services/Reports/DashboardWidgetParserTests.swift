import Foundation
import Testing
@testable import Actuali

@MainActor
struct DashboardWidgetParserTests {

    @Test func parsesSummaryCard() throws {
        let widget = DashboardWidget.parse(
            id: "w1",
            type: "summary-card",
            metaJSON: #"{"name":"Spent This Month","content":{"type":"sum"}}"#
        )
        if case .summary(let id, let meta) = widget {
            #expect(id == "w1")
            #expect(meta?.name == "Spent This Month")
        } else {
            Issue.record("Expected .summary, got \(widget)")
        }
    }

    @Test func parsesNetWorthCard() throws {
        let widget = DashboardWidget.parse(
            id: "w2",
            type: "net-worth-card",
            metaJSON: #"{"name":"Net Worth","interval":"Monthly"}"#
        )
        if case .netWorth(let id, let meta) = widget {
            #expect(id == "w2")
            #expect(meta?.name == "Net Worth")
            #expect(meta?.interval == .monthly)
        } else {
            Issue.record("Expected .netWorth")
        }
    }

    @Test func parsesCashFlowCard() throws {
        let widget = DashboardWidget.parse(
            id: "w3",
            type: "cash-flow-card",
            metaJSON: #"{"name":"Cash Flow","showBalance":true}"#
        )
        if case .cashFlow(let id, let meta) = widget {
            #expect(id == "w3")
            #expect(meta?.showBalance == true)
        } else {
            Issue.record("Expected .cashFlow")
        }
    }

    @Test func parsesSpendingCard() throws {
        let widget = DashboardWidget.parse(
            id: "w4",
            type: "spending-card",
            metaJSON: #"{"name":"Spending","mode":"average"}"#
        )
        if case .spending(let id, let meta) = widget {
            #expect(id == "w4")
            #expect(meta?.mode == .average)
        } else {
            Issue.record("Expected .spending")
        }
    }

    @Test func parsesMarkdownCard() throws {
        let widget = DashboardWidget.parse(
            id: "w5",
            type: "markdown-card",
            metaJSON: "{\"content\":\"# Hello\\nWorld\"}"
        )
        if case .markdown(let id, let meta) = widget {
            #expect(id == "w5")
            #expect(meta.content == "# Hello\nWorld")
        } else {
            Issue.record("Expected .markdown")
        }
    }

    @Test func unknownTypeBecomesUnsupported() throws {
        let widget = DashboardWidget.parse(
            id: "w6",
            type: "future-card",
            metaJSON: #"{"name":"From The Future"}"#
        )
        if case .unsupported(let id, let type) = widget {
            #expect(id == "w6")
            #expect(type == "future-card")
        } else {
            Issue.record("Expected .unsupported")
        }
    }

    @Test func parsesCalendarCard() throws {
        let widget = DashboardWidget.parse(
            id: "w10", type: "calendar-card",
            metaJSON: #"{"name":"Calendar","timeFrame":{"mode":"sliding-window","start":"2026-04","end":"2026-05"}}"#
        )
        if case .calendar(let id, let meta) = widget {
            #expect(id == "w10")
            #expect(meta?.name == "Calendar")
            #expect(meta?.timeFrame?.mode == .slidingWindow)
        } else {
            Issue.record("Expected .calendar")
        }
    }

    @Test func parsesCrossoverCard() throws {
        let widget = DashboardWidget.parse(
            id: "w11", type: "crossover-card",
            metaJSON: #"{"name":"FI","safeWithdrawalRate":0.04,"projectionType":"hampel"}"#
        )
        if case .crossover(let id, let meta) = widget {
            #expect(id == "w11")
            #expect(meta?.safeWithdrawalRate == 0.04)
        } else {
            Issue.record("Expected .crossover")
        }
    }

    @Test func parsesBudgetAnalysisCard() throws {
        let widget = DashboardWidget.parse(
            id: "w12", type: "budget-analysis-card",
            metaJSON: #"{"name":"Budget vs Actual","graphType":"Bar","showBalance":true}"#
        )
        if case .budgetAnalysis(let id, let meta) = widget {
            #expect(id == "w12")
            #expect(meta?.name == "Budget vs Actual")
        } else {
            Issue.record("Expected .budgetAnalysis")
        }
    }

    @Test func parsesSankeyCard() throws {
        let widget = DashboardWidget.parse(
            id: "w13", type: "sankey-card",
            metaJSON: #"{"name":"Money Flow","mode":"spent","topNcategories":5}"#
        )
        if case .sankey(let id, let meta) = widget {
            #expect(id == "w13")
            #expect(meta?.topNcategories == 5)
        } else {
            Issue.record("Expected .sankey")
        }
    }

    @Test func parsesBalanceForecastCard() throws {
        let widget = DashboardWidget.parse(
            id: "w14", type: "balance-forecast-card",
            metaJSON: #"{"name":"Forecast","granularity":"Monthly","source":"tracking-budget"}"#
        )
        if case .balanceForecast(let id, let meta) = widget {
            #expect(id == "w14")
            #expect(meta?.source == .trackingBudget)
        } else {
            Issue.record("Expected .balanceForecast")
        }
    }

    @Test func parsesMonteCarloCard() throws {
        let widget = DashboardWidget.parse(
            id: "w15", type: "monte-carlo-card",
            metaJSON: #"{"name":"Retirement","currentAge":40,"targetAge":90,"simulationCount":1000}"#
        )
        if case .monteCarlo(let id, let meta) = widget {
            #expect(id == "w15")
            #expect(meta?.currentAge == 40)
        } else {
            Issue.record("Expected .monteCarlo")
        }
    }

    @Test func malformedJsonForKnownTypeBecomesUnsupported() throws {
        // Note: for non-markdown types, a malformed/missing JSON yields .summary(meta: nil),
        // not .unsupported, because their meta is optional. Only markdown REQUIRES content
        // and thus falls through to .unsupported when JSON is bad.
        let widget = DashboardWidget.parse(
            id: "w7",
            type: "markdown-card",
            metaJSON: "{this is not json"
        )
        if case .unsupported(let id, let type) = widget {
            #expect(id == "w7")
            #expect(type == "markdown-card")
        } else {
            Issue.record("Expected .unsupported for malformed JSON")
        }
    }

    @Test func nilMetaIsAllowedForOptionalMetaTypes() throws {
        let widget = DashboardWidget.parse(
            id: "w8",
            type: "summary-card",
            metaJSON: nil
        )
        if case .summary(let id, let meta) = widget {
            #expect(id == "w8")
            #expect(meta == nil)
        } else {
            Issue.record("Expected .summary with nil meta")
        }
    }

    @Test func markdownWithNilMetaIsUnsupported() throws {
        let widget = DashboardWidget.parse(
            id: "w9",
            type: "markdown-card",
            metaJSON: nil
        )
        if case .unsupported(let id, let type) = widget {
            #expect(id == "w9")
            #expect(type == "markdown-card")
        } else {
            Issue.record("Expected .unsupported for markdown with nil meta")
        }
    }

    @Test func displayNameUsesMetaNameWhenSet() throws {
        let widget = DashboardWidget.parse(
            id: "w10",
            type: "summary-card",
            metaJSON: #"{"name":"My Summary"}"#
        )
        #expect(widget.displayName == "My Summary")
    }

    @Test func displayNameFallsBackToTypeLabel() throws {
        let widget = DashboardWidget.parse(
            id: "w11",
            type: "summary-card",
            metaJSON: "{}"
        )
        #expect(widget.displayName == "Summary")
    }

    @Test func parsesAgeOfMoneyCard() throws {
        let meta = """
        {"conditions":[{"field":"account","op":"onBudget","value":null,"type":"id"}],
         "conditionsOp":"and",
         "timeFrame":{"start":"2025-06","end":"2026-06","mode":"full"},
         "granularity":"monthly"}
        """
        let widget = DashboardWidget.parse(id: "w1", type: "age-of-money-card", metaJSON: meta)
        if case .ageOfMoney(let id, let parsed) = widget {
            #expect(id == "w1")
            #expect(parsed?.timeFrame?.mode == .full)
            #expect(parsed?.granularity == "monthly")
            #expect(parsed?.conditions?.count == 1)
            #expect(widget.displayName == "Age of Money")
        } else {
            Issue.record("Expected .ageOfMoney, got \(widget)")
        }
    }

    @Test func parsesFormulaCard() throws {
        let meta = """
        {"name":"Saved This Month","fontSize":41.9,
         "formula":"=query(\\"expenses\\")+query(\\"income\\")",
         "queries":{"expenses":{"conditions":[{"field":"amount","op":"lt","value":0,"type":"number"}],
                                "conditionsOp":"and",
                                "timeFrame":{"start":"2026-04-01","end":"2026-04-30","mode":"sliding-window"}}}}
        """
        let widget = DashboardWidget.parse(id: "w2", type: "formula-card", metaJSON: meta)
        if case .formula(_, let parsed) = widget {
            #expect(parsed?.formula == "=query(\"expenses\")+query(\"income\")")
            #expect(parsed?.queries?["expenses"]?.timeFrame?.mode == .slidingWindow)
            #expect(widget.displayName == "Saved This Month")
        } else {
            Issue.record("Expected .formula, got \(widget)")
        }
    }

    @Test func parsesCustomReportCard() throws {
        let widget = DashboardWidget.parse(
            id: "w3",
            type: "custom-report",
            metaJSON: #"{"id":"1878500d-0aca-495a-9602-271aac118dcf"}"#
        )
        if case .customReport(_, let parsed) = widget {
            #expect(parsed?.id == "1878500d-0aca-495a-9602-271aac118dcf")
            #expect(widget.displayName == "Custom Report")
        } else {
            Issue.record("Expected .customReport, got \(widget)")
        }
    }

    @Test func widgetIdReturnsCorrectIdForAllCases() throws {
        #expect(DashboardWidget.summary(id: "a", meta: nil).id == "a")
        #expect(DashboardWidget.netWorth(id: "b", meta: nil).id == "b")
        #expect(DashboardWidget.cashFlow(id: "c", meta: nil).id == "c")
        #expect(DashboardWidget.spending(id: "d", meta: nil).id == "d")
        #expect(DashboardWidget.markdown(id: "e", meta: MarkdownMeta(content: "hi", textAlign: nil)).id == "e")
        #expect(DashboardWidget.ageOfMoney(id: "g", meta: nil).id == "g")
        #expect(DashboardWidget.formula(id: "h", meta: nil).id == "h")
        #expect(DashboardWidget.customReport(id: "i", meta: nil).id == "i")
        #expect(DashboardWidget.unsupported(id: "f", type: "sankey-card").id == "f")
    }
}
