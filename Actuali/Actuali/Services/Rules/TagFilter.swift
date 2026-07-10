import Foundation

/// Tag extraction and matching shared by the rule engine and report filters.
/// Port of upstream loot-core `shared/tags.ts` (`extractTagsForFilter`) plus
/// the tag pattern from `server/rules/condition.ts` / the AQL filter path.
/// The rule engine matches case-insensitively (it lowercases both sides);
/// AQL filters stay case-sensitive — callers pick via `caseSensitive`.
enum TagFilter {

    /// Every whitespace-separated token (leading `#`s stripped) becomes a
    /// `#token` tag, deduped preserving order:
    /// "one #one ##one ##two three" → ["#one", "#two", "#three"]
    static func extractTags(_ value: String) -> [String] {
        var seen = Set<String>()
        var tags: [String] = []
        for token in value.split(whereSeparator: { $0.isWhitespace || $0 == "#" }) {
            let tag = "#" + token
            if seen.insert(tag).inserted { tags.append(tag) }
        }
        return tags
    }

    /// Matches upstream's tag pattern `(?<!#)tag([\s#]|$)`: the tag must not
    /// be preceded by an extra `#` (so `##hidden` tags never match) and must
    /// end at whitespace, another tag, or the end of the notes.
    static func notesContainTag(_ notes: String, tag: String, caseSensitive: Bool) -> Bool {
        let needle = caseSensitive ? tag : tag.lowercased()
        let haystack = caseSensitive ? notes : notes.lowercased()
        let escaped = NSRegularExpression.escapedPattern(for: needle)
        guard let regex = try? NSRegularExpression(pattern: "(?<!#)\(escaped)([\\s#]|$)") else {
            return false
        }
        let range = NSRange(haystack.startIndex..., in: haystack)
        return regex.firstMatch(in: haystack, range: range) != nil
    }
}
