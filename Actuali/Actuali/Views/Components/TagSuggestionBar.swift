import SwiftUI

/// Pure logic for hashtag autocomplete detection and completion.
enum TagSuggestionHelper {
    /// Inspects whether the end of `text` is an active `#hashtag` being typed.
    /// Returns the tag prefix query (e.g. "vac" for "#vac", or "" for "#") and the range of the token.
    static func activeTagToken(in text: String) -> (query: String, range: Range<String.Index>)? {
        guard let hashIndex = text.lastIndex(of: "#") else { return nil }

        // Must not be escaped ##
        if hashIndex > text.startIndex {
            let prevIndex = text.index(before: hashIndex)
            if text[prevIndex] == "#" {
                return nil
            }
        }

        // Everything from # to end of string must be a single word (no whitespace or newlines)
        let tokenSubstring = text[hashIndex...]
        if tokenSubstring.contains(where: { $0.isWhitespace || $0.isNewline }) {
            return nil
        }

        let query = String(tokenSubstring.dropFirst())
        return (query: query, range: hashIndex..<text.endIndex)
    }

    /// Replaces the active `#token` in `text` with `#\(completedTag) `.
    static func applyTagCompletion(_ completedTag: String, to text: String) -> String {
        guard let token = activeTagToken(in: text) else {
            return text + " #\(completedTag) "
        }
        var copy = text
        copy.replaceSubrange(token.range, with: "#\(completedTag) ")
        return copy
    }

    /// Filters available tags matching `query`. If `query` is empty (user just typed `#`), returns all active tags.
    static func matchingTags(from tags: [Tag], query: String) -> [Tag] {
        let cleanQuery = query.lowercased()
        let activeTags = tags.filter { !$0.tombstone && !$0.hidden }
        if cleanQuery.isEmpty {
            return activeTags
        }
        return activeTags.filter { $0.tag.lowercased().hasPrefix(cleanQuery) }
    }
}

/// Horizontal suggestion bar displaying matching tag chips when typing `#` in a note.
struct TagSuggestionBar: View {
    @Binding var text: String
    let availableTags: [Tag]

    private var activeToken: (query: String, range: Range<String.Index>)? {
        TagSuggestionHelper.activeTagToken(in: text)
    }

    private var suggestions: [Tag] {
        guard let activeToken else { return [] }
        return TagSuggestionHelper.matchingTags(from: availableTags, query: activeToken.query)
    }

    var body: some View {
        if !suggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions) { tag in
                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                text = TagSuggestionHelper.applyTagCompletion(tag.tag, to: text)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(tag.swiftUIColor)
                                    .frame(width: 8, height: 8)
                                Text(tag.displayName)
                                    .font(.subheadline.weight(.medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color(.secondarySystemFill), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("tagSuggestion-\(tag.tag)")
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
        }
    }
}
