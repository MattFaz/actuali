import Foundation
import SwiftUI
import Testing
@testable import Actuali

struct TagTests {
    @Test func tagInitializationAndDefaults() {
        let tag = Tag(tag: "vacation")
        #expect(tag.tag == "vacation")
        #expect(tag.displayName == "#vacation")
        #expect(tag.color == nil)
        #expect(tag.description == nil)
        #expect(tag.hidden == false)
        #expect(tag.tombstone == false)
        #expect(!tag.id.isEmpty)
    }

    @Test func normalizeTagNameStripsHashAndWhitespace() {
        #expect(Tag.normalizeTagName("#groceries") == "groceries")
        #expect(Tag.normalizeTagName("  #food  ") == "food")
        #expect(Tag.normalizeTagName("###travel") == "travel")
        #expect(Tag.normalizeTagName("trip-2026") == "trip-2026")
    }

    @Test func isValidTagName() {
        #expect(Tag.isValidTagName("vacation"))
        #expect(Tag.isValidTagName("#vacation"))
        #expect(Tag.isValidTagName("trip-2026"))
        #expect(Tag.isValidTagName("food_drinks"))
        #expect(!Tag.isValidTagName(""))
        #expect(!Tag.isValidTagName("   "))
        #expect(!Tag.isValidTagName("#"))
        #expect(!Tag.isValidTagName("two words"))
        #expect(!Tag.isValidTagName("has#inside"))
    }

    @Test func syncableFieldsSerialization() {
        let tag = Tag(
            id: "tag-1",
            tag: "work",
            color: "#3b82f6",
            description: "Work expenses",
            hidden: true,
            tombstone: false
        )
        let fields = tag.syncableFields
        #expect(fields["id"] as? String == "tag-1")
        #expect(fields["tag"] as? String == "work")
        #expect(fields["color"] as? String == "#3b82f6")
        #expect(fields["description"] as? String == "Work expenses")
        #expect(fields["hidden"] as? Int == 1)
        #expect(fields["tombstone"] as? Int == 0)
        #expect(Tag.datasetName == "tags")
    }

    @Test func colorHexParsing() {
        let tagWithColor = Tag(tag: "travel", color: "#EF4444")
        _ = tagWithColor.swiftUIColor
        #expect(Tag.presetColors.contains("#ef4444"))
    }

    @Test func extractHashtagsFromNotesOnlyExtractsRealHashtags() {
        let note = "Team lunch #reimbursable #food"
        let tags = TagFilter.extractHashtags(from: note)
        #expect(tags == ["#reimbursable", "#food"])

        let plainNote = "Just normal text without any tags"
        #expect(TagFilter.extractHashtags(from: plainNote).isEmpty)

        let hiddenNote = "##hidden note #visible"
        #expect(TagFilter.extractHashtags(from: hiddenNote) == ["#visible"])
    }

    @Test func colorToHexSupportsGrayscaleAndRgb() {
        let red = Color(hex: "#FF0000")
        #expect(red?.toHex() == "#FF0000")

        let white = Color(white: 1.0, opacity: 1.0)
        #expect(white.toHex() == "#FFFFFF")

        let black = Color(white: 0.0, opacity: 1.0)
        #expect(black.toHex() == "#000000")
    }

    @Test func tagSummaryCalculatesFields() {
        let tag = Tag(id: "tag-1", tag: "groceries")
        let summary = TagSummary(tag: tag, transactionCount: 5, totalSpent: 12500, netAmount: -12500)
        #expect(summary.id == "tag-1")
        #expect(summary.transactionCount == 5)
        #expect(summary.totalSpent == 12500)
        #expect(summary.netAmount == -12500)
    }
}
