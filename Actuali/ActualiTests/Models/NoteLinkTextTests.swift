import Foundation
import Testing
@testable import Actuali

struct NoteLinkTextTests {

    /// Every URL attached to a link run, in note order.
    private func linkURLs(_ text: String) -> [URL] {
        NoteLinkText.links(in: text).map(\.url)
    }

    // MARK: - attributed(_:)

    @Test func markdownLinkBecomesTappableLabel() {
        let attributed = NoteLinkText.attributed("Order: [Amazon](https://amazon.com/gp/order/123)")
        #expect(String(attributed.characters) == "Order: Amazon")
        let linkRun = attributed.runs.first { $0.link != nil }
        #expect(linkRun?.link == URL(string: "https://amazon.com/gp/order/123"))
    }

    @Test func bareURLBecomesLink() {
        let attributed = NoteLinkText.attributed("Receipt at https://example.com/r/9 filed")
        // Bare URLs keep their text — nothing is rewritten, only linkified.
        #expect(String(attributed.characters) == "Receipt at https://example.com/r/9 filed")
        let linkRun = attributed.runs.first { $0.link != nil }
        #expect(linkRun?.link == URL(string: "https://example.com/r/9"))
    }

    @Test func plainTextGetsNoLinks() {
        let attributed = NoteLinkText.attributed("Cap at $400/mo — fuel comes out of Transport.")
        #expect(attributed.runs.allSatisfy { $0.link == nil })
    }

    @Test func newlinesSurviveParsing() {
        let attributed = NoteLinkText.attributed("Line one\nLine two")
        #expect(String(attributed.characters) == "Line one\nLine two")
    }

    // MARK: - links(in:)

    @Test func extractsMarkdownLabelAndURL() {
        let links = NoteLinkText.links(in: "See [Amazon order](https://amazon.com/gp/order/123).")
        #expect(links.count == 1)
        #expect(links.first?.label == "Amazon order")
        #expect(links.first?.url == URL(string: "https://amazon.com/gp/order/123"))
    }

    @Test func extractsBareURLWithItsTextAsLabel() {
        let links = NoteLinkText.links(in: "Manual: https://example.com/manual.pdf")
        #expect(links.count == 1)
        #expect(links.first?.label == "https://example.com/manual.pdf")
        #expect(links.first?.url == URL(string: "https://example.com/manual.pdf"))
    }

    @Test func schemelessURLGetsAScheme() {
        let urls = linkURLs("see www.example.com for details")
        #expect(urls.count == 1)
        // NSDataDetector normalizes to an openable URL; without a scheme
        // openURL would silently no-op.
        #expect(urls.first?.scheme != nil)
        #expect(urls.first?.host == "www.example.com")
    }

    @Test func mixedMarkdownAndBareURLsKeepNoteOrder() {
        let links = NoteLinkText.links(
            in: "[Rule](https://amazon.com/rule) and also https://example.com/x"
        )
        #expect(links.map(\.label) == ["Rule", "https://example.com/x"])
        #expect(links.map(\.url) == [
            URL(string: "https://amazon.com/rule"),
            URL(string: "https://example.com/x"),
        ].compactMap { $0 })
    }

    @Test func markdownURLIsNotDoubleDetected() {
        // The detector pass must skip ranges the markdown pass already linked.
        let links = NoteLinkText.links(in: "[https://example.com](https://example.com)")
        #expect(links.count == 1)
    }

    @Test func noLinksMeansEmpty() {
        #expect(NoteLinkText.links(in: "just words").isEmpty)
        #expect(NoteLinkText.links(in: "").isEmpty)
    }
}
