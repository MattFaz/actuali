// Actuali/Actuali/Services/Sync/HLCTimestamp.swift

import Foundation

/// Hybrid Logical Clock timestamp
/// Format: 2025-12-09T14:30:45.123Z-0000-9f66d38cba0ef956
///         |ISO 8601 timestamp    |cntr|node ID (16 hex)
struct HLCTimestamp: Comparable, Hashable, Codable, CustomStringConvertible {
    let millis: Int64      // Wall clock time in milliseconds
    let counter: UInt16    // Logical counter for same-millisecond events
    let node: String       // 16-char hex device ID

    // MARK: - Formatting

    var description: String {
        toString()
    }

    func toString() -> String {
        // Format milliseconds as ISO 8601
        let seconds = Double(millis) / 1000.0
        let date = Date(timeIntervalSince1970: seconds)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoString = formatter.string(from: date)

        // Format counter as 4-digit uppercase hex
        let counterHex = String(format: "%04X", counter)

        // Ensure node is 16 chars, padded with leading zeros
        let paddedNode = String(repeating: "0", count: Swift.max(0, 16 - node.count)) + node.suffix(16)

        return "\(isoString)-\(counterHex)-\(paddedNode)"
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

        // Parse ISO date
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: String(isoString)) else { return nil }

        let millis = Int64(date.timeIntervalSince1970 * 1000)

        // Validate millis range (1970 to 9999)
        guard millis >= 0 && millis < 253402300800000 else { return nil }

        // Parse counter (hex)
        guard let counter = UInt16(parts[3], radix: 16) else { return nil }

        // Parse node
        let node = String(parts[4])
        guard node.count <= 16 else { return nil }

        return HLCTimestamp(millis: millis, counter: counter, node: node)
    }

    /// Minutes since the Unix epoch for a timestamp string, read straight off
    /// its ISO-8601 prefix (`YYYY-MM-DDTHH:MM`, always UTC).
    ///
    /// `parse` builds an `ISO8601DateFormatter` per call, which dominates any
    /// pass over a whole message log — and the Merkle trie only ever needs the
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
            if separator, iterator.next() == nil { return nil }
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
        let yearOfEra = shiftedYear - era * 400                                  // [0, 399]
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1 // [0, 365]
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return Int64(era) * 146_097 + Int64(dayOfEra) - 719_468
    }

    // MARK: - Comparable

    static func < (lhs: HLCTimestamp, rhs: HLCTimestamp) -> Bool {
        // Lexicographic comparison of string representation works correctly
        lhs.toString() < rhs.toString()
    }

    // MARK: - Hashing (for Merkle tree)

    /// Returns hash as Int32 to match JavaScript's signed 32-bit XOR behavior
    func hash() -> Int32 {
        Int32(bitPattern: MurmurHash3.hash(toString()))
    }

    // MARK: - Constants

    static let zero = HLCTimestamp(millis: 0, counter: 0, node: "0000000000000000")
    static let max = HLCTimestamp(millis: 253402300799999, counter: 0xFFFF, node: "FFFFFFFFFFFFFFFF")

    /// Create a "since" timestamp for a given ISO date string
    static func since(_ isoString: String) -> String {
        "\(isoString)-0000-0000000000000000"
    }
}
