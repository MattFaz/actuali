import Foundation
import Testing
@testable import Actuali

/// `parse` reads the one shape upstream writes off its fixed positions and
/// leaves every other string to `ISO8601DateFormatter`, as before.
struct HLCTimestampParseTests {
    /// `parse` as it was when the formatter read every date.
    private static func formatterParse(_ string: String, _ formatter: ISO8601DateFormatter) -> HLCTimestamp? {
        let parts = string.split(separator: "-")
        guard parts.count == 5,
              let date = formatter.date(from: "\(parts[0])-\(parts[1])-\(parts[2])")
        else { return nil }
        let millis = Int64(date.timeIntervalSince1970 * 1000)
        guard millis >= 0, millis < 253_402_300_800_000,
              let counter = UInt16(parts[3], radix: 16), parts[4].count <= 16
        else { return nil }
        return HLCTimestamp(millis: millis, counter: counter, node: String(parts[4]))
    }

    /// What upstream's own `Timestamp.parse` (packages/crdt/src/crdt/timestamp.ts)
    /// returns for these strings. Each sits in a stretch where seconds held in
    /// a `Double`, times 1000 and truncated, came out a millisecond low.
    @Test func parseMatchesUpstreamWhereTruncationLostAMillisecond() {
        let upstream: [(String, Int64, UInt16)] = [
            ("2004-08-21T02:21:35.179Z-E993-a1b2c3d4e5f60718", 1_093_054_895_179, 59795),
            ("2004-08-13T07:30:12.501Z-1AEB-a1b2c3d4e5f60718", 1_092_382_212_501, 6891),
            ("2039-05-17T11:39:59.713Z-2AA6-a1b2c3d4e5f60718", 2_189_245_199_713, 10918),
            ("2039-03-20T09:56:59.897Z-C533-a1b2c3d4e5f60718", 2_184_227_819_897, 50483),
        ]
        for (string, millis, counter) in upstream {
            #expect(HLCTimestamp.parse(string) == HLCTimestamp(millis: millis, counter: counter, node: "a1b2c3d4e5f60718"))
        }
    }

    /// A timestamp has to come back as the string it arrived as: that string
    /// is what gets stored and hashed into the merkle tree. The truncation
    /// above broke that for about a quarter of the timestamps between
    /// 2038-01-19 and 2039-09-07, and for none between 2015 and 2030.
    @Test func parseReadsTheExactMillisecond() {
        var generator = SeededGenerator()
        var wrong: [String] = []
        var millisToCheck: [Int64] = [0, 999, 253_402_300_799_999, 2_193_942_060_161]
        for _ in 0..<50000 {
            millisToCheck.append(Int64(generator.next(253_402_300_800_000)))
            // 2015 to 2045, where real timestamps are and will be.
            millisToCheck.append(1_420_070_400_000 + Int64(generator.next(946_771_200_000)))
        }
        for millis in millisToCheck {
            let written = HLCTimestamp(millis: millis, counter: 0x1a2b, node: "a1b2c3d4e5f60718").toString()
            if HLCTimestamp.parse(written)?.toString() != written {
                wrong.append(written)
            }
        }
        #expect(wrong.isEmpty, "\(wrong.prefix(5))")
    }

    /// Timestamps come from the server, so what counts as one must not shift:
    /// the same strings are accepted and refused as when the formatter read
    /// them all, with the same value apart from that lost millisecond.
    @Test func parseAcceptsExactlyWhatTheFormatterDid() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var generator = SeededGenerator()
        var strings: [String] = []
        // Calendar and clock edges in the canonical shape.
        for year in [0, 1969, 1970, 1900, 2000, 2023, 2024, 2100, 9999] {
            for (month, day) in [(0, 1), (1, 0), (1, 31), (1, 32), (2, 28), (2, 29), (2, 30), (4, 31), (12, 31), (13, 1)] {
                for time in ["00:00:00.000", "23:59:59.999", "24:00:00.000", "23:60:00.000", "23:59:60.000"] {
                    strings.append(String(format: "%04d-%02d-%02dT%@Z-0000-a1b2c3d4e5f60718", year, month, day, time))
                }
            }
        }
        // Valid timestamps with a character or two overwritten, dropped or added.
        let alphabet = Array("0123456789-:.TZtz+ ,aAfF/")
        for _ in 0..<20000 {
            let millis = 1_420_070_400_000 + Int64(generator.next(473_385_600_000))
            var characters = Array(HLCTimestamp(millis: millis, counter: 7, node: "a1b2c3d4e5f60718").toString())
            for _ in 0...generator.next(2) {
                let index = Int(generator.next(26))
                switch generator.next(4) {
                case 0: characters.remove(at: index)
                case 1: characters.insert(alphabet[Int(generator.next(UInt64(alphabet.count)))], at: index)
                default: characters[index] = alphabet[Int(generator.next(UInt64(alphabet.count)))]
                }
            }
            strings.append(String(characters))
        }

        var accepted = 0
        var disagreements: [String] = []
        for string in strings {
            let now = HLCTimestamp.parse(string)
            let before = Self.formatterParse(string, formatter)
            accepted += before == nil ? 0 : 1
            let sameValue = now == before || now.map { HLCTimestamp(millis: $0.millis - 1, counter: $0.counter, node: $0.node) } == before
            if (now == nil) != (before == nil) || !sameValue {
                disagreements.append(string)
            }
        }
        #expect(disagreements.isEmpty, "\(disagreements.prefix(5))")
        // Guards the generator: both outcomes have to be well represented.
        #expect(accepted > 1000)
        #expect(strings.count - accepted > 1000)
    }
}
