import Foundation
import Testing
@testable import Actuali

/// Upstream orders timestamps by their string form, and sync compatibility
/// rests on that order. `<` compares the fields instead, so it has to agree
/// with the string comparison everywhere a timestamp can actually be.
struct HLCTimestampOrderingTests {
    private static let nodes = [
        "a1b2c3d4e5f60718", "A1B2C3D4E5F60718", "0000000000000000", "ffffffffffffffff",
        "9f66d38cba0ef956", "0", "abc", "89e0e8e90b203f9e",
    ]

    @Test func fieldOrderMatchesStringOrder() {
        var generator = SeededGenerator()
        // Bases spread over the whole range `parse` accepts, each with a few
        // neighbours at equal and adjacent milliseconds, so that the date
        // formatting is checked everywhere and the counter and node get to decide.
        let lastMillis: UInt64 = 253_402_300_799_999
        var base: UInt64 = 1_780_000_000_000
        var timestamps: [HLCTimestamp] = []
        for _ in 0..<600 {
            if generator.next(4) == 0 {
                base = generator.next(lastMillis - 1)
            }
            let millis = base + generator.next(3)
            timestamps.append(HLCTimestamp(
                millis: Int64(millis),
                counter: UInt16(generator.next(2) == 0 ? generator.next(3) : generator.next(65536)),
                node: Self.nodes[Int(generator.next(UInt64(Self.nodes.count)))]
            ))
        }
        timestamps += [.zero, .max]
        let strings = timestamps.map { $0.toString() }

        var disagreements: [String] = []
        for left in timestamps.indices {
            for right in timestamps.indices where (timestamps[left] < timestamps[right]) != (strings[left] < strings[right]) {
                disagreements.append("\(strings[left]) vs \(strings[right])")
            }
        }
        #expect(disagreements.isEmpty, "\(disagreements.prefix(5))")
        // Guards the generator: a narrow one once kept every base in January 1970.
        #expect(Set(strings.map { $0.prefix(2) }).count > 50)
    }

    @Test func sortingAgreesWithSortingTheStrings() {
        var generator = SeededGenerator()
        let timestamps = (0..<2000).map { _ in
            HLCTimestamp(
                millis: 1_780_000_000_000 + Int64(generator.next(5000)),
                counter: UInt16(generator.next(4)),
                node: Self.nodes[Int(generator.next(4))]
            )
        }
        #expect(timestamps.sorted().map { $0.toString() } == timestamps.map { $0.toString() }.sorted())
    }
}
