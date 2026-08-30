import Testing
@testable import Actuali

struct CleanupTemplatesTests {

    @Test func parsesCleanupNoteLines() {
        let note = """
        #cleanup source
        #cleanup sink 3
        #cleanup Vacation source
        #cleanup Vacation Fund sink 2
        #cleanup Holidays
        not a cleanup line
        """
        let rows = CleanupNotes.parseRows(fromNote: note)
        #expect(rows == [
            .init(kind: .source, groupName: nil),
            .init(kind: .sink(weight: 3), groupName: nil),
            .init(kind: .source, groupName: "Vacation"),
            .init(kind: .sink(weight: 2), groupName: "Vacation Fund"),
            .init(kind: .overspend, groupName: "Holidays"),
        ])
    }

    @Test func parsesCRLFNoteLines() {
        let rows = CleanupNotes.parseRows(
            fromNote: "#cleanup source\r\n#cleanup Vacation sink\r\n")
        #expect(rows == [
            .init(kind: .source, groupName: nil),
            .init(kind: .sink(weight: 1), groupName: "Vacation"),
        ])
    }

    @Test func resolvesRowsToTemplates() {
        let rows = CleanupNotes.parseRows(fromNote: "#cleanup Vacation sink\n#cleanup Ghost")
        let templates = CleanupNotes.toTemplates(rows) { name in
            name.lowercased() == "vacation" ? "grp-1" : nil
        }
        // Unknown overspend groups are dropped, matching upstream's guard.
        #expect(templates == [.sink(groupId: "grp-1", weight: 1)])
    }

    @Test func jsonRoundTrip() throws {
        let rows: [CleanupTemplate] = [
            .source(),
            .sink(weight: 2),
            .source(groupId: "grp-1"),
            .overspend(groupId: "grp-2"),
        ]
        let encoded = try #require(CleanupTemplate.encodeArray(rows))
        let decoded = try #require(CleanupTemplate.decodeArray(fromJSON: encoded))
        #expect(decoded == rows)
    }

    @Test func decodesUpstreamShape() throws {
        let json = """
        [{"role":"source","groupId":null},
         {"role":"sink","groupId":null,"weight":2},
         {"role":"overspend","groupId":"grp-1"}]
        """
        let decoded = try #require(CleanupTemplate.decodeArray(fromJSON: json))
        #expect(decoded == [.source(), .sink(weight: 2), .overspend(groupId: "grp-1")])
    }

    @Test func configRoundTrip() {
        let rows: [CleanupTemplate] = [
            .source(),
            .sink(weight: 3),
            .source(groupId: "grp-1"),
            .sink(groupId: "grp-1", weight: 2),
            .overspend(groupId: "grp-2"),
        ]
        let config = CleanupConfig.from(cleanup: rows)
        #expect(config.global.send)
        #expect(config.global.take)
        #expect(config.global.weight == 3)
        #expect(config.groups.count == 2)
        let group1 = config.groups.first { $0.groupId == "grp-1" }
        #expect(group1?.send == true)
        #expect(group1?.take == true)
        #expect(group1?.overspendOnly == false)
        let group2 = config.groups.first { $0.groupId == "grp-2" }
        #expect(group2?.take == true)
        #expect(group2?.overspendOnly == true)

        #expect(config.toCleanupTemplates() == rows)
    }

    @Test func emptyConfigProducesNoRows() {
        #expect(!CleanupConfig().isConfigured)
        #expect(CleanupConfig().toCleanupTemplates().isEmpty)
    }

    @Test func rendersNotesFromTemplates() {
        let rendered = CleanupNotes.toNotes([
            .source(),
            .sink(weight: 2),
            .source(groupId: "grp-1"),
            .overspend(groupId: "grp-2"),
        ]) { id in
            id == "grp-1" ? "Vacation" : id == "grp-2" ? "Holidays" : nil
        }
        #expect(rendered == """
        #cleanup source
        #cleanup sink 2
        #cleanup Vacation source
        #cleanup Holidays
        """)
    }
}
