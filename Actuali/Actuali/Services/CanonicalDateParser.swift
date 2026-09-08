import Foundation

enum CanonicalDateParser {

    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static func parse(_ string: String) -> Date? {
        let bytes = Array(string.utf8)
        guard bytes.count == 4 || bytes.count == 7 || bytes.count == 10,
              bytes[0...3].allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        if bytes.count >= 7 {
            guard bytes[4] == 45,
                  bytes[5...6].allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        }
        if bytes.count == 10 {
            guard bytes[7] == 45,
                  bytes[8...9].allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        }

        let year = Int(String(decoding: bytes[0...3], as: UTF8.self))!
        let month = bytes.count == 4 ? nil : Int(String(decoding: bytes[5...6], as: UTF8.self))
        let day = bytes.count == 10 ? Int(String(decoding: bytes[8...9], as: UTF8.self)) : nil
        let components = DateComponents(year: year, month: month, day: day ?? 1)
        guard let date = calendar.date(from: components) else { return nil }
        let parsed = calendar.dateComponents([.year, .month, .day], from: date)
        guard parsed.year == year,
              parsed.month == (month ?? 1),
              parsed.day == (day ?? 1) else { return nil }
        return date
    }

    static func parseMonthOrDay(_ string: String) -> Date? {
        guard string.utf8.count == 7 || string.utf8.count == 10 else { return nil }
        return parse(string)
    }

    static func parseMonthStart(_ string: String) -> Date? {
        guard let date = parseMonthOrDay(string) else { return nil }
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: DateComponents(year: components.year, month: components.month, day: 1))
    }
}