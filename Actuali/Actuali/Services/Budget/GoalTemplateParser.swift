import Foundation

/// Hand-rolled port of loot-core's `goal-template.pegjs` grammar. Same
/// ordered-choice semantics as peggy: alternatives are tried top to bottom,
/// each must consume the entire line, and the first full match wins.
///
/// Whitespace mirrors the grammar's `_` rule ([ \t]*, i.e. optional), so the
/// same slightly-permissive inputs upstream accepts ("#template 3days…",
/// "repeatevery") parse identically here.
enum GoalTemplateParser {

    struct ParseError: Error {
        let message: String
    }

    /// Parse one `#template…` / `#goal…` line (already trimmed to start at
    /// the `#`). Throws on lines that match no grammar alternative.
    static func parse(_ line: String) throws -> GoalTemplate {
        var scanner = Scanner(line)

        // `#goal`i amount
        if scanner.matchLiteral("#goal", caseInsensitive: true) {
            guard let amount = scanner.amount(), scanner.isAtEnd else {
                throw ParseError(message: "Invalid #goal syntax")
            }
            var template = GoalTemplate(type: .goal, directive: .goal, priority: nil)
            template.amount = amount
            return template
        }

        // `#template` is case-sensitive upstream.
        guard scanner.matchLiteral("#template", caseInsensitive: false) else {
            throw ParseError(message: "Line is not a template")
        }
        // priority = '-' number; absent coerces to 0 (upstream's `+null`).
        var priority = 0
        if scanner.matchLiteral("-", caseInsensitive: false) {
            guard let n = scanner.number() else {
                throw ParseError(message: "Invalid priority")
            }
            priority = n
        }

        let alternatives: [(inout Scanner) -> GoalTemplate?] = [
            parsePercentage, parsePeriodic, parseByOrSpend, parseSimpleWithAmount,
            parseSimpleLimitOnly, parseSchedule, parseRemainder, parseAverage, parseCopy,
        ]
        let body = scanner // position after the prefix
        for alternative in alternatives {
            var attempt = body
            if var template = alternative(&attempt), attempt.isAtEnd {
                template.priority = template.type == .remainder ? nil : priority
                return template
            }
        }
        throw ParseError(message: "Invalid template syntax")
    }

    // MARK: - Alternatives (bodies after the `#template[-N]` prefix)

    /// percent '%' of ['previous'] name
    private static func parsePercentage(_ s: inout Scanner) -> GoalTemplate? {
        s.skipWhitespace()
        guard let percent = s.percent() else { return nil }
        s.skipWhitespace()
        guard s.matchLiteral("of", caseInsensitive: true) else { return nil }
        s.skipWhitespace()
        var previous = false
        // Grammar has only optional whitespace after 'previous', so
        // "of previousSalary" parses as previous + "Salary" upstream too.
        if s.matchLiteral("previous", caseInsensitive: true) {
            previous = true
            s.skipWhitespace()
        }
        guard let name = s.restOfLine(), !name.isEmpty else { return nil }
        var template = GoalTemplate(type: .percentage, directive: .template)
        template.percent = percent
        template.previous = previous
        template.category = name
        return template
    }

    /// amount 'repeat every' periodCount 'starting' date [limit]
    private static func parsePeriodic(_ s: inout Scanner) -> GoalTemplate? {
        s.skipWhitespace()
        guard let amount = s.amount() else { return nil }
        s.skipWhitespace()
        guard s.matchLiteral("repeat", caseInsensitive: true) else { return nil }
        s.skipWhitespace()
        guard s.matchLiteral("every", caseInsensitive: true) else { return nil }
        s.skipWhitespace()
        guard let period = s.periodCount() else { return nil }
        s.skipWhitespace()
        guard s.matchLiteral("starting", caseInsensitive: true) else { return nil }
        s.skipWhitespace()
        guard let starting = s.date() else { return nil }
        let limit = s.limit()
        var template = GoalTemplate(type: .periodic, directive: .template)
        template.amount = amount
        template.period = period
        template.starting = starting
        template.limit = limit
        return template
    }

    /// amount 'by' month ['spend from' month] ['repeat every' repeat]
    private static func parseByOrSpend(_ s: inout Scanner) -> GoalTemplate? {
        s.skipWhitespace()
        guard let amount = s.amount() else { return nil }
        s.skipWhitespace()
        guard s.matchLiteral("by", caseInsensitive: true) else { return nil }
        s.skipWhitespace()
        guard let month = s.month() else { return nil }

        var from: String?
        var attempt = s
        attempt.skipWhitespace()
        if attempt.matchLiteral("spend", caseInsensitive: true) {
            attempt.skipWhitespace()
            if attempt.matchLiteral("from", caseInsensitive: true) {
                attempt.skipWhitespace()
                if let fromMonth = attempt.month() {
                    from = fromMonth
                    s = attempt
                }
            }
        }

        var annual: Bool?
        var repeatCount: Int?
        attempt = s
        attempt.skipWhitespace()
        if attempt.matchLiteral("repeat", caseInsensitive: true) {
            attempt.skipWhitespace()
            if attempt.matchLiteral("every", caseInsensitive: true) {
                attempt.skipWhitespace()
                if let repeatInterval = attempt.repeatInterval() {
                    annual = repeatInterval.annual
                    repeatCount = repeatInterval.repeatCount
                    s = attempt
                }
            }
        }

        var template = GoalTemplate(type: from != nil ? .spend : .by, directive: .template)
        template.amount = amount
        template.month = month
        template.from = from
        template.annual = annual
        template.repeatCount = repeatCount
        return template
    }

    /// amount [limit]
    private static func parseSimpleWithAmount(_ s: inout Scanner) -> GoalTemplate? {
        s.skipWhitespace()
        guard let monthly = s.amount() else { return nil }
        let limit = s.limit()
        var template = GoalTemplate(type: .simple, directive: .template)
        template.monthly = monthly
        template.limit = limit
        return template
    }

    /// limit only (monthly = null)
    private static func parseSimpleLimitOnly(_ s: inout Scanner) -> GoalTemplate? {
        guard let limit = s.limit() else { return nil }
        var template = GoalTemplate(type: .simple, directive: .template)
        template.limit = limit
        return template
    }

    /// 'schedule' ['full'] name [modifiers]
    private static func parseSchedule(_ s: inout Scanner) -> GoalTemplate? {
        s.skipWhitespace()
        guard s.matchLiteral("schedule", caseInsensitive: true) else { return nil }
        s.skipWhitespace()
        var full = false
        // Upstream's `full = 'full'i _` — no word boundary, so a schedule
        // named "Fuller House" loses its prefix there too. Kept identical.
        if s.matchLiteral("full", caseInsensitive: true) {
            full = true
            s.skipWhitespace()
        }
        guard let (name, modifiers) = s.scheduleNameAndModifiers(), !name.isEmpty
        else { return nil }
        var template = GoalTemplate(type: .schedule, directive: .template)
        template.name = name
        template.full = full ? true : nil
        template.adjustment = modifiers?.adjustment
        template.adjustmentType = modifiers?.adjustmentType
        return template
    }

    /// 'remainder' [weight] [limit]
    private static func parseRemainder(_ s: inout Scanner) -> GoalTemplate? {
        s.skipWhitespace()
        guard s.matchLiteral("remainder", caseInsensitive: true) else { return nil }
        s.skipWhitespace()
        let weight = s.positive() ?? 1
        let limit = s.limit()
        var template = GoalTemplate(type: .remainder, directive: .template)
        template.weight = Double(weight)
        template.limit = limit
        return template
    }

    /// 'average' positive ['months'] [modifiers]
    private static func parseAverage(_ s: inout Scanner) -> GoalTemplate? {
        s.skipWhitespace()
        guard s.matchLiteral("average", caseInsensitive: true) else { return nil }
        s.skipWhitespace()
        guard let numMonths = s.positive() else { return nil }
        s.skipWhitespace()
        _ = s.matchLiteral("months", caseInsensitive: true)
        let modifiers = s.modifiers()
        var template = GoalTemplate(type: .average, directive: .template)
        template.numMonths = numMonths
        template.adjustment = modifiers?.adjustment
        template.adjustmentType = modifiers?.adjustmentType
        return template
    }

    /// 'copy from' positive 'months ago' [limit]
    private static func parseCopy(_ s: inout Scanner) -> GoalTemplate? {
        s.skipWhitespace()
        guard s.matchLiteral("copy from", caseInsensitive: true) else { return nil }
        s.skipWhitespace()
        guard let lookBack = s.positive() else { return nil }
        s.skipWhitespace()
        guard s.matchLiteral("months ago", caseInsensitive: true) else { return nil }
        let limit = s.limit()
        var template = GoalTemplate(type: .copy, directive: .template)
        template.lookBack = lookBack
        template.limit = limit
        return template
    }

    // MARK: - Scanner

    struct Scanner {
        private let characters: [Character]
        private var position = 0

        init(_ string: String) {
            characters = Array(string)
        }

        var isAtEnd: Bool { position >= characters.count }

        private func peek(_ offset: Int = 0) -> Character? {
            let index = position + offset
            return index < characters.count ? characters[index] : nil
        }

        /// `_` in the grammar: zero or more spaces/tabs.
        mutating func skipWhitespace() {
            while let c = peek(), c == " " || c == "\t" { position += 1 }
        }

        mutating func matchLiteral(_ literal: String, caseInsensitive: Bool) -> Bool {
            let target = Array(literal)
            guard position + target.count <= characters.count else { return false }
            for (offset, expected) in target.enumerated() {
                let actual = characters[position + offset]
                let matches = caseInsensitive
                    ? String(actual).lowercased() == String(expected).lowercased()
                    : actual == expected
                if !matches { return false }
            }
            position += target.count
            return true
        }

        private mutating func digits(min: Int = 1, max: Int = Int.max) -> String? {
            var result = ""
            while result.count < max, let c = peek(), c.isNumber, c.isASCII {
                result.append(c)
                position += 1
            }
            if result.count < min {
                position -= result.count
                return nil
            }
            return result
        }

        mutating func number() -> Int? {
            digits().flatMap(Int.init)
        }

        /// `[1-9][0-9]*`
        mutating func positive() -> Int? {
            guard let c = peek(), c.isNumber, c != "0" else { return nil }
            return number()
        }

        /// currencySymbol? _? '-'? digits ('.' digit{0,2})?
        mutating func amount() -> Double? {
            let start = position
            if let c = peek(), c.unicodeScalars.count == 1,
               c.unicodeScalars.first.map({ $0.properties.generalCategory == .currencySymbol }) == true {
                position += 1
            }
            skipWhitespace()
            var text = ""
            if peek() == "-" {
                text.append("-")
                position += 1
            }
            guard let whole = digits() else {
                position = start
                return nil
            }
            text += whole
            if peek() == "." {
                position += 1
                let fraction = digits(min: 0, max: 2) ?? ""
                text += ".\(fraction)"
            }
            // Trailing-dot inputs ("5.") coerce like JS `+'5.'`.
            return Double(text.hasSuffix(".") ? String(text.dropLast()) : text)
        }

        /// digits ('.' digits)? _? '%'
        mutating func percent() -> Double? {
            let start = position
            var text = ""
            guard let whole = digits() else { return nil }
            text += whole
            if peek() == "." {
                position += 1
                if let fraction = digits() { text += ".\(fraction)" }
            }
            skipWhitespace()
            guard peek() == "%" else {
                position = start
                return nil
            }
            position += 1
            return Double(text)
        }

        /// Exactly `dddd-dd`.
        mutating func month() -> String? {
            let start = position
            guard let year = digits(min: 4, max: 4), peek() == "-" else {
                position = start
                return nil
            }
            position += 1
            guard let monthDigits = digits(min: 2, max: 2) else {
                position = start
                return nil
            }
            return "\(year)-\(monthDigits)"
        }

        /// Exactly `dddd-dd-dd`.
        mutating func date() -> String? {
            let start = position
            guard let monthPart = month(), peek() == "-" else {
                position = start
                return nil
            }
            position += 1
            guard let day = digits(min: 2, max: 2) else {
                position = start
                return nil
            }
            return "\(monthPart)-\(day)"
        }

        mutating func restOfLine() -> String? {
            var result = ""
            while let c = peek(), c != "\r", c != "\n", c != "\t" {
                result.append(c)
                position += 1
            }
            return result
        }

        /// periodCount: day | N days | week | N weeks | N months | year | N years
        mutating func periodCount() -> GoalTemplate.Period? {
            if matchLiteral("day", caseInsensitive: true), !nextIsLetter("s") {
                return .init(period: .day, amount: 1)
            }
            if matchLiteral("week", caseInsensitive: true), !nextIsLetter("s") {
                return .init(period: .week, amount: 1)
            }
            if matchLiteral("year", caseInsensitive: true), !nextIsLetter("s") {
                return .init(period: .year, amount: 1)
            }
            let start = position
            guard let n = number() else { return nil }
            skipWhitespace()
            if matchLiteral("days", caseInsensitive: true) { return .init(period: .day, amount: n) }
            if matchLiteral("weeks", caseInsensitive: true) { return .init(period: .week, amount: n) }
            if matchLiteral("months", caseInsensitive: true) { return .init(period: .month, amount: n) }
            if matchLiteral("years", caseInsensitive: true) { return .init(period: .year, amount: n) }
            position = start
            return nil
        }

        /// Peg's bare 'day'/'week'/'year' literals happily match the prefix of
        /// "days"/"weeks"/"years" and then fail the sequence as a whole; the
        /// N-suffixed alternatives require a leading number, so a bare plural
        /// never parses upstream either. Checking the next character here gets
        /// the same outcome without full alternative-level backtracking.
        private func nextIsLetter(_ letter: Character) -> Bool {
            guard let c = peek() else { return false }
            return String(c).lowercased() == String(letter).lowercased()
        }

        /// repeat: month | N months | year | N years
        mutating func repeatInterval() -> (annual: Bool, repeatCount: Int?)? {
            if matchLiteral("month", caseInsensitive: true), !nextIsLetter("s") {
                return (false, nil)
            }
            if matchLiteral("year", caseInsensitive: true), !nextIsLetter("s") {
                return (true, nil)
            }
            let start = position
            guard let n = positive() else { return nil }
            skipWhitespace()
            if matchLiteral("months", caseInsensitive: true) { return (false, n) }
            if matchLiteral("years", caseInsensitive: true) { return (true, n) }
            position = start
            return nil
        }

        /// limit: 'up to' amount ['per week starting' date | 'per day'] ['hold']
        mutating func limit() -> GoalTemplate.Limit? {
            let start = position
            skipWhitespace()
            guard matchLiteral("up", caseInsensitive: true) else {
                position = start
                return nil
            }
            skipWhitespace()
            guard matchLiteral("to", caseInsensitive: true) else {
                position = start
                return nil
            }
            skipWhitespace()
            guard let amount = amount() else {
                position = start
                return nil
            }

            var attempt = self
            attempt.skipWhitespace()
            if attempt.matchLiteral("per week starting", caseInsensitive: true) {
                attempt.skipWhitespace()
                if let startDate = attempt.date() {
                    attempt.skipWhitespace()
                    let hold = attempt.matchLiteral("hold", caseInsensitive: true)
                    self = attempt
                    return .init(amount: amount, hold: hold, period: .weekly, start: startDate)
                }
            }

            attempt = self
            attempt.skipWhitespace()
            if attempt.matchLiteral("per day", caseInsensitive: true) {
                attempt.skipWhitespace()
                let hold = attempt.matchLiteral("hold", caseInsensitive: true)
                self = attempt
                return .init(amount: amount, hold: hold, period: .daily, start: nil)
            }

            skipWhitespace()
            let hold = matchLiteral("hold", caseInsensitive: true)
            return .init(amount: amount, hold: hold, period: .monthly, start: nil)
        }

        /// modifiers: '[' ('increase'|'decrease') value['%'] ']'
        mutating func modifiers() -> (adjustment: Double, adjustmentType: GoalTemplate.AdjustmentType)? {
            let start = position
            skipWhitespace()
            guard matchLiteral("[", caseInsensitive: false) else {
                position = start
                return nil
            }
            let sign: Double
            if matchLiteral("increase", caseInsensitive: true) {
                sign = 1
            } else if matchLiteral("decrease", caseInsensitive: true) {
                sign = -1
            } else {
                position = start
                return nil
            }
            skipWhitespace()
            var text = ""
            guard let whole = digits() else {
                position = start
                return nil
            }
            text += whole
            if peek() == "." {
                position += 1
                if let fraction = digits() { text += ".\(fraction)" }
            }
            // The grammar allows whitespace before '%' but requires ']'
            // immediately after the value/percent — "[increase 5 ]" fails.
            var afterValue = self
            afterValue.skipWhitespace()
            let isPercent = afterValue.matchLiteral("%", caseInsensitive: false)
            if isPercent { self = afterValue }
            guard matchLiteral("]", caseInsensitive: false), let value = Double(text) else {
                position = start
                return nil
            }
            return (sign * value, isPercent ? .percent : .fixed)
        }

        /// rawScheduleName + optional trailing modifiers: everything up to a
        /// `[increase…]`/`[decrease…]` block (or end of line), trimmed.
        mutating func scheduleNameAndModifiers()
            -> (name: String, modifiers: (adjustment: Double, adjustmentType: GoalTemplate.AdjustmentType)?)? {
            guard let c = peek(), c != " ", c != "\t", c != "\r", c != "\n" else { return nil }
            var name = ""
            while !isAtEnd {
                var attempt = self
                if let modifiers = attempt.modifiers() {
                    self = attempt
                    return (name.trimmingCharacters(in: .whitespaces), modifiers)
                }
                guard let next = peek(), next != "\r", next != "\n" else { break }
                name.append(next)
                position += 1
            }
            return (name.trimmingCharacters(in: .whitespaces), nil)
        }
    }
}

// MARK: - Note extraction

/// Port of loot-core `template-notes.ts` `getCategoriesWithTemplates`: pull
/// template lines out of one category note, keeping non-directive lines
/// directly above a template line as its description.
enum GoalTemplateNotes {
    static let templatePrefix = "#template"
    static let goalPrefix = "#goal"
    static let cleanupPrefix = "#cleanup"

    static func parseTemplates(fromNote note: String) -> [GoalTemplate] {
        var templates: [GoalTemplate] = []
        var descriptionLines: [String] = []

        for line in note.components(separatedBy: "\n") {
            // Upstream takes `line.substring(line.indexOf('#'))` — the whole
            // line when there is no '#' (JS substring(-1) starts at 0).
            let fromHash = line.firstIndex(of: "#").map { String(line[$0...]) } ?? line
            let trimmedLine = fromHash.trimmingCharacters(in: .whitespacesAndNewlines)
            let isTemplateLine = trimmedLine.hasPrefix(templatePrefix)
                || trimmedLine.hasPrefix(goalPrefix)

            if !isTemplateLine {
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || trimmedLine.hasPrefix(cleanupPrefix) {
                    descriptionLines = []
                } else {
                    descriptionLines.append(trimTrailing(line))
                }
                continue
            }

            let description = descriptionLines.isEmpty ? nil : descriptionLines.joined(separator: "\n")
            descriptionLines = []

            var template: GoalTemplate
            do {
                template = try GoalTemplateParser.parse(trimmedLine)
                // Adjustment bounds check, mirroring template-notes.ts.
                if template.type == .average || template.type == .schedule,
                   let adjustment = template.adjustment,
                   template.adjustmentType == .percent,
                   adjustment <= -100 || adjustment > 1000 {
                    var errorTemplate = GoalTemplate(type: .error, directive: .error)
                    errorTemplate.line = line
                    errorTemplate.error = "Invalid adjustment percentage (\(trimTrailingZeros(adjustment))%). Must be between -100% and 1000%"
                    template = errorTemplate
                }
            } catch {
                var errorTemplate = GoalTemplate(type: .error, directive: .error)
                errorTemplate.line = line
                errorTemplate.error = (error as? GoalTemplateParser.ParseError)?.message
                    ?? "Invalid template syntax"
                template = errorTemplate
            }
            template.description = description
            templates.append(template)
        }
        return templates
    }

    /// Whether a note contains any template/goal directive at all — the
    /// cheap gate before parsing, mirroring the upstream SQL LIKE filter.
    static func noteHasTemplates(_ note: String) -> Bool {
        let lowered = note.lowercased()
        return lowered.contains(templatePrefix) || lowered.contains(goalPrefix)
    }

    private static func trimTrailing(_ line: String) -> String {
        var result = line
        while let last = result.last, last == " " || last == "\t" || last == "\r" {
            result.removeLast()
        }
        return result
    }

    private static func trimTrailingZeros(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
