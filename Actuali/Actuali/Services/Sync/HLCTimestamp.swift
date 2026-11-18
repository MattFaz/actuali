// Actuali/Actuali/Services/Sync/HLCTimestamp.swift

import Foundation
import Synchronization

/// Hybrid Logical Clock timestamp
/// Format: 2025-12-09T14:30:45.123Z-0000-9f66d38cba0ef956
///         |ISO 8601 timestamp    |cntr|node ID (16 hex)
struct HLCTimestamp: Comparable, Hashable, Codable, CustomStringConvertible {
    let millis: Int64 // Wall clock time in milliseconds
    let counter: UInt16 // Logical counter for same-millisecond events
    let node: String // 16-char hex device ID

    // MARK: - Formatting

    /// One formatter for every call: building one per timestamp dominated a
    /// long sync. Behind a lock because `ISO8601DateFormatter`, unlike
    /// `DateFormatter`, does no locking of its own.
    private static let isoFormatter: Mutex<ISO8601DateFormatter> = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Mutex(formatter)
    }()

    var description: String {
        toString()
    }

    func toString() -> String {
        // Format milliseconds as ISO 8601
        let seconds = Double(millis) / 1000.0
        let date = Date(timeIntervalSince1970: seconds)

        let isoString = Self.isoFormatter.withLock { $0.string(from: date) }

        // Format counter as 4-digit uppercase hex
        let counterHex = String(format: "%04X", counter)

        return "\(isoString)-\(counterHex)-\(paddedNode)"
    }

    /// The node as it is written out: 16 chars, padded with leading zeros.
    private var paddedNode: String {
        String(repeating: "0", count: Swift.max(0, 16 - node.count)) + node.suffix(16)
    }

    // MARK: - Parsing

    /// Parse a timestamp string into an HLCTimestamp
    /// Returns nil if the string is invalid
    static func parse(_ string: String) -> HLCTimestamp? {
        // Format: 2015-04-24T22:23:42.123Z-1000-0123456789ABCDEF
        // Split by "-" but ISO date has dashes too, so split smartly
        let parts = string.split(separator: "-")
        guard parts.count == 5 else { return nil }

        // Reconstruct ISO date from first 3 parts
        let isoString = "\(parts[0])-\(parts[1])-\(parts[2])"

        // Parse ISO date. Anything but the one shape upstream writes goes to
        // the formatter, so what is accepted stays exactly what it was.
        let millis: Int64
        if let canonical = canonicalMillis(isoString) {
            millis = canonical
        } else {
            guard let date = Self.isoFormatter.withLock({ $0.date(from: isoString) }) else { return nil }
            millis = Int64(date.timeIntervalSince1970 * 1000)
        }

        // Validate millis range (1970 to 9999)
        guard millis >= 0, millis < 253_402_300_800_000 else { return nil }

        // Parse counter (hex)
        guard let counter = UInt16(parts[3], radix: 16) else { return nil }

        // Parse node
        let node = String(parts[4])
        guard node.count <= 16 else { return nil }

        return HLCTimestamp(millis: millis, counter: counter, node: node)
    }

    /// Milliseconds since the Unix epoch for `YYYY-MM-DDTHH:MM:SS.mmmZ`, the
    /// shape JavaScript's `toISOString()` gives every upstream timestamp, read
    /// off its fixed positions: `ISO8601DateFormatter` takes about 50 µs to
    /// parse one, which was half of a long sync. Nil for any other shape and
    /// for a date the calendar doesn't have, leaving those to the formatter.
    private static func canonicalMillis(_ iso: String) -> Int64? {
        let bytes = Array(iso.utf8)
        guard bytes.count == 24 else { return nil }
        for (index, separator) in zip([4, 7, 10, 13, 16, 19, 23], "--T::.Z".utf8) where bytes[index] != separator {
            return nil
        }
        func field(_ range: Range<Int>) -> Int? {
            var value = 0
            for byte in bytes[range] {
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard let year = field(0..<4), let month = field(5..<7), let day = field(8..<10),
              let hour = field(11..<13), let minute = field(14..<16), let second = field(17..<19),
              let fraction = field(20..<23),
              year >= 1970, (1...12).contains(month), hour < 24, minute < 60, second < 60
        else { return nil }
        let isLeapYear = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let daysInMonth = [31, isLeapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        guard (1...daysInMonth).contains(day) else { return nil }

        let seconds = daysSinceEpoch(year: year, month: month, day: day) * 86400
            + Int64(hour * 3600 + minute * 60 + second)
        return seconds * 1000 + Int64(fraction)
    }

    /// Minutes since the Unix epoch for a timestamp string, read straight off
    /// its ISO-8601 prefix (`YYYY-MM-DDTHH:MM`, always UTC).
    ///
    /// `parse` formats a date behind a shared lock, which a pass over a whole
    /// message log still feels, and the Merkle trie only ever needs the
    /// minute (`MerkleTree` keys on `millis / 1000 / 60`), never the full
    /// timestamp. Returns nil if the prefix isn't well formed.
    static func minutesSinceEpoch(of string: String) -> Int64? {
        var iterator = string.utf8.makeIterator()
        // Fixed-width fields, each followed by one separator ("-", "-", "T", ":").
        func field(digits: Int, separator: Bool) -> Int? {
            var value = 0
            for _ in 0..<digits {
                guard let byte = iterator.next(), byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            if separator, iterator.next() == nil {
                return nil
            }
            return value
        }
        guard let year = field(digits: 4, separator: true),
              let month = field(digits: 2, separator: true),
              let day = field(digits: 2, separator: true),
              let hour = field(digits: 2, separator: true),
              let minute = field(digits: 2, separator: false),
              (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60
        else { return nil }

        return daysSinceEpoch(year: year, month: month, day: day) * 1440
            + Int64(hour * 60 + minute)
    }

    /// Days from 1970-01-01 to a proleptic-Gregorian date (Howard Hinnant's
    /// `days_from_civil`), shifting the year to start in March so the leap day
    /// lands at the end of the cycle.
    private static func daysSinceEpoch(year: Int, month: Int, day: Int) -> Int64 {
        let shiftedYear = year - (month <= 2 ? 1 : 0)
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400 // [0, 399]
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1 // [0, 365]
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return Int64(era) * 146_097 + Int64(dayOfEra) - 719_468
    }

    // MARK: - Comparable

    static func < (lhs: HLCTimestamp, rhs: HLCTimestamp) -> Bool {
        // Upstream orders timestamps by their string form. Every field in it
        // is fixed width, so comparing the fields in order gives the same
        // answer without formatting a date per operand: sorting a first sync's
        // tens of thousands of messages spent minutes building formatters.
        if lhs.millis != rhs.millis {
            return lhs.millis < rhs.millis
        }
        if lhs.counter != rhs.counter {
            return lhs.counter < rhs.counter
        }
        return lhs.paddedNode < rhs.paddedNode
    }

    // MARK: - Hashing (for Merkle tree)

    /// Returns hash as Int32 to match JavaScript's signed 32-bit XOR behavior
    func hash() -> Int32 {
        Int32(bitPattern: MurmurHash3.hash(toString()))
    }

    // MARK: - Constants

    static let zero = HLCTimestamp(millis: 0, counter: 0, node: "0000000000000000")
    static let max = HLCTimestamp(millis: 253_402_300_799_999, counter: 0xffff, node: "FFFFFFFFFFFFFFFF")

    /// Create a "since" timestamp for a given ISO date string
    static func since(_ isoString: String) -> String {
        "\(isoString)-0000-0000000000000000"
    }
}
