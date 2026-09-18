import SwiftUI

struct MarkdownWidgetView: View {
    let meta: MarkdownMeta

    private var frameAlignment: Alignment {
        switch meta.textAlign {
        case .center: .center
        case .right: .trailing
        default: .leading
        }
    }

    private var textAlignment: TextAlignment {
        switch meta.textAlign {
        case .center: .center
        case .right: .trailing
        default: .leading
        }
    }

    private var attributed: AttributedString {
        if let parsed = try? AttributedString(
            markdown: meta.content,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return parsed
        }
        return AttributedString(meta.content)
    }

    var body: some View {
        Text(attributed)
            .multilineTextAlignment(textAlignment)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .padding()
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    VStack {
        MarkdownWidgetView(meta: MarkdownMeta(
            content: "## Weekly review\nThings went **well** this week.",
            textAlign: .left
        ))
        MarkdownWidgetView(meta: MarkdownMeta(
            content: "Quick note — see [docs](https://example.com).",
            textAlign: .center
        ))
    }
    .padding()
}
