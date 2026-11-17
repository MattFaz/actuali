import Foundation
import Testing
@testable import Actuali

/// The string form is what gets stored, sent and hashed into the merkle tree,
/// so it has to stay exactly upstream's: `toISOString()`, a 4 digit uppercase
/// hex counter and a 16 character node.
struct HLCTimestampFormatTests {
    private static let known: [(string: String, millis: Int64, counter: UInt16)] = [
        ("2019-06-03T16:40:53.876Z-0000-9f66d38cba0ef956", 1_559_580_053_876, 0),
        ("2026-11-17T04:11:52.001Z-00AF-9f66d38cba0ef956", 1_794_888_712_001, 0xaf),
        ("1970-01-01T00:00:00.000Z-FFFF-9f66d38cba0ef956", 0, 0xffff),
        ("9999-12-31T23:59:59.999Z-0001-9f66d38cba0ef956", 253_402_300_799_999, 1),
    ]

    @Test func writesAndReadsUpstreamsFormat() {
        for (string, millis, counter) in Self.known {
            let timestamp = HLCTimestamp(millis: millis, counter: counter, node: "9f66d38cba0ef956")
            #expect(timestamp.toString() == string)
            #expect(HLCTimestamp.parse(string) == timestamp)
        }
    }

    /// Every timestamp goes through one shared formatter, from the sync
    /// actor, the main actor and the database queue. Many tasks at once must
    /// each still get their own answer.
    @Test func formatsCorrectlyFromManyTasksAtOnce() async {
        let wrong = await withTaskGroup(of: Int.self) { group in
            for task in 0..<8 {
                group.addTask {
                    var wrong = 0
                    for index in 0..<2000 {
                        // A different second per task, so a swapped answer shows.
                        let millis = 1_780_000_000_000 + Int64(task) * 1000 + Int64(index % 1000)
                        let expected = String(format: "2026-05-28T20:26:%02d.%03dZ-0000-9f66d38cba0ef956", 40 + task, index % 1000)
                        let timestamp = HLCTimestamp(millis: millis, counter: 0, node: "9f66d38cba0ef956")
                        if timestamp.toString() != expected || HLCTimestamp.parse(expected) != timestamp {
                            wrong += 1
                        }
                    }
                    return wrong
                }
            }
            return await group.reduce(0, +)
        }
        #expect(wrong == 0)
    }
}
