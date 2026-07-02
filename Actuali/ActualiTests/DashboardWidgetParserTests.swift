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
            type: "sankey-card",
            metaJSON: #"{"name":"Money Flow"}"#
        )
        if case .unsupported(let id, let type) = widget {
            #expect(id == "w6")
            #expect(type == "sankey-card")
        } else {
            Issue.record("Expected .unsupported")
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

    @Test func widgetIdReturnsCorrectIdForAllCases() throws {
        #expect(DashboardWidget.summary(id: "a", meta: nil).id == "a")
        #expect(DashboardWidget.netWorth(id: "b", meta: nil).id == "b")
        #expect(DashboardWidget.cashFlow(id: "c", meta: nil).id == "c")
        #expect(DashboardWidget.spending(id: "d", meta: nil).id == "d")
        #expect(DashboardWidget.markdown(id: "e", meta: MarkdownMeta(content: "hi", textAlign: nil)).id == "e")
        #expect(DashboardWidget.unsupported(id: "f", type: "sankey-card").id == "f")
    }
}
