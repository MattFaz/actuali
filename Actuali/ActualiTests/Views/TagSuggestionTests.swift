import Foundation
import Testing
@testable import Actuali

struct TagSuggestionTests {
    @Test func detectsActiveTagTokenAtEndOfText() {
        let token1 = TagSuggestionHelper.activeTagToken(in: "Lunch with #")
        #expect(token1 != nil)
        #expect(token1?.query == "")

        let token2 = TagSuggestionHelper.activeTagToken(in: "Lunch with #vac")
        #expect(token2 != nil)
        #expect(token2?.query == "vac")

        let token3 = TagSuggestionHelper.activeTagToken(in: "Just notes")
        #expect(token3 == nil)

        // Trailing whitespace means the hashtag is finished
        let token4 = TagSuggestionHelper.activeTagToken(in: "Lunch with #vac ")
        #expect(token4 == nil)

        // Escaped ## is not a tag
        let token5 = TagSuggestionHelper.activeTagToken(in: "Escaped ##tag")
        #expect(token5 == nil)
    }

    @Test func appliesTagCompletionCorrectly() {
        let text1 = "Lunch with #v"
        let completed1 = TagSuggestionHelper.applyTagCompletion("vacation", to: text1)
        #expect(completed1 == "Lunch with #vacation ")

        let text2 = "#"
        let completed2 = TagSuggestionHelper.applyTagCompletion("food", to: text2)
        #expect(completed2 == "#food ")

        let text3 = "Meeting notes #tea"
        let completed3 = TagSuggestionHelper.applyTagCompletion("team", to: text3)
        #expect(completed3 == "Meeting notes #team ")
    }

    @Test func matchingTagsFiltersCorrectly() {
        let tags = [
            Tag(id: "1", tag: "vacation"),
            Tag(id: "2", tag: "vehicle"),
            Tag(id: "3", tag: "food"),
            Tag(id: "4", tag: "hidden-tag", hidden: true),
            Tag(id: "5", tag: "deleted-tag", tombstone: true),
        ]

        let matchesEmpty = TagSuggestionHelper.matchingTags(from: tags, query: "")
        #expect(matchesEmpty.map(\.tag) == ["vacation", "vehicle", "food"])

        let matchesV = TagSuggestionHelper.matchingTags(from: tags, query: "v")
        #expect(matchesV.map(\.tag) == ["vacation", "vehicle"])

        let matchesVac = TagSuggestionHelper.matchingTags(from: tags, query: "VAC")
        #expect(matchesVac.map(\.tag) == ["vacation"])

        let matchesNonExistent = TagSuggestionHelper.matchingTags(from: tags, query: "xyz")
        #expect(matchesNonExistent.isEmpty)
    }
}
