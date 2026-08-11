import Foundation

/// One tappable link found in a note: the text the user reads and the URL it
/// opens. `label` is the markdown link's title, or the URL text itself for
/// bare URLs.
struct NoteLink: Identifiable, Equatable {
    let label: String
    let url: URL
    /// Position within the note, so repeated links stay distinct rows.
    let position: Int

    var id: Int { position }
}

/// Turns note text into tappable links (GH #190). Notes written in Actual
/// commonly carry markdown links (e.g. a rule that links a transaction to its
/// Amazon order page), and sometimes bare URLs pasted straight in.
///
/// Two passes: inline markdown first — the same parsing MarkdownWidgetView
/// uses for dashboard widgets — then NSDataDetector over what markdown left
/// unlinked, so `[label](url)` and pasted URLs both become links without
/// double-linking the markdown ones.
enum NoteLinkText {

    /// The note rendered for display: markdown links become link runs, bare
    /// URLs are linkified in place. Falls back to the raw text if markdown
    /// parsing rejects the note — a note must never display as empty.
    static func attributed(_ text: String) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(text)
        detectBareURLs(in: &attributed)
        return attributed
    }

    /// Every link in the note, in note order — for edit surfaces, where the
    /// text sits in a TextField/TextEditor and can't be tappable itself, so
    /// links render as separate rows beneath it.
    static func links(in text: String) -> [NoteLink] {
        let attributed = attributed(text)
        var links: [NoteLink] = []
        // Consecutive runs can share one URL (markdown labels with styled
        // spans), so coalesce by URL before splitting into rows.
        for (url, range) in attributed.runs[\.link] {
            guard let url else { continue }
            let label = String(attributed[range].characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            links.append(NoteLink(label: label, url: url, position: links.count))
        }
        return links
    }

    /// Adds `.link` to detector matches that markdown didn't already link.
    /// NSDataDetector also normalizes schemeless matches ("www.example.com")
    /// to openable http URLs.
    private static func detectBareURLs(in attributed: inout AttributedString) {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return }
        let plain = String(attributed.characters)
        let matches = detector.matches(
            in: plain,
            range: NSRange(plain.startIndex..., in: plain)
        )
        for match in matches {
            guard let url = match.url,
                  let range = Range(match.range, in: attributed),
                  attributed[range].runs.allSatisfy({ $0.link == nil })
            else { continue }
            attributed[range].link = url
        }
    }
}
