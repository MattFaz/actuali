import Foundation

/// Native evaluator for formula-card widgets. Upstream runs formulas through
/// HyperFormula (a full spreadsheet engine); we support the basic subset used
/// by common cards — numbers, strings, query("name"), IF, ABS, ROUND,
/// comparisons, arithmetic, and concatenation — and surface anything else as
/// `.unsupported` so the card explains itself instead of guessing.
enum FormulaEngine {

    enum Result: Equatable {
        /// Currency units (upstream integerToAmount: cents / 100).
        case value(Double)
        case text(String)
        case unsupported(String)
    }

    static func compute(
        meta: FormulaMeta?,
        transactions: [Transaction],
        today: Date,
        context: ConditionsFilter.Context
    ) -> Result {
        guard let formula = meta?.formula, formula.hasPrefix("=") else {
            return .unsupported("Formula must start with =")
        }
        var parser = Parser(String(formula.dropFirst()))
        guard let expr = parser.parseExpression() else {
            return .unsupported("This formula isn't supported yet")
        }
        do {
            let result = try evaluate(expr) { name in
                querySum(named: name, meta: meta, transactions: transactions,
                         today: today, context: context)
            }
            switch result {
            case .number(let value):
                guard value.isFinite else {
                    return .unsupported("This formula isn't supported yet")
                }
                return .value(value)
            case .text(let value): return .text(value)
            case .boolean(let value): return .text(value ? "TRUE" : "FALSE")
            }
        } catch EvalError.divisionByZero {
            return .unsupported("Division by zero")
        } catch {
            return .unsupported("This formula isn't supported yet")
        }
    }

    /// Sum (currency units) of transactions matching the named query's
    /// conditions and time frame. Unknown names are 0, like upstream.
    private static func querySum(
        named name: String,
        meta: FormulaMeta?,
        transactions: [Transaction],
        today: Date,
        context: ConditionsFilter.Context
    ) -> Double {
        guard let query = meta?.queries?[name] else { return 0 }

        var pool = transactions.filter { !$0.tombstone }
        // Upstream only date-filters when the timeFrame has a mode.
        if let timeFrame = query.timeFrame, timeFrame.mode != nil {
            let (start, end) = TimeFrame.resolve(timeFrame, asOf: today)
            let startYMD = ymdInt(from: start), endYMD = ymdInt(from: end)
            pool = pool.filter { $0.date >= startYMD && $0.date <= endYMD }
        }
        let cents = pool
            .filter { ConditionsFilter.matches(transaction: $0,
                                               conditions: query.conditions,
                                               op: query.conditionsOp,
                                               context: context) }
            .reduce(0) { $0 + $1.amount }
        return Double(cents) / 100
    }

    private static func ymdInt(from date: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    indirect enum Expr: Equatable {
        case number(Double), string(String), function(String, [Expr])
        case add(Expr, Expr), sub(Expr, Expr), mul(Expr, Expr), div(Expr, Expr)
        case neg(Expr), compare(String, Expr, Expr), concat(Expr, Expr)
    }

    private enum Value: Equatable { case number(Double), text(String), boolean(Bool) }
    private enum EvalError: Error { case divisionByZero, invalidArguments, invalidType }

    private static func evaluate(_ expr: Expr, query: (String) -> Double) throws -> Value {
        switch expr {
        case .number(let n): return .number(n)
        case .string(let value): return .text(value)
        case .function(let name, let args): return try evaluateFunction(name, args: args, query: query)
        case .add(let l, let r): return .number(try number(l, query: query) + number(r, query: query))
        case .sub(let l, let r): return .number(try number(l, query: query) - number(r, query: query))
        case .mul(let l, let r): return .number(try number(l, query: query) * number(r, query: query))
        case .div(let l, let r):
            let divisor = try number(r, query: query)
            guard abs(divisor) > .ulpOfOne else { throw EvalError.divisionByZero }
            return .number(try number(l, query: query) / divisor)
        case .neg(let e): return .number(try -number(e, query: query))
        case .compare(let op, let left, let right):
            return .boolean(try compare(
                op,
                left: evaluate(left, query: query),
                right: evaluate(right, query: query)))
        case .concat(let left, let right):
            return .text(stringValue(try evaluate(left, query: query)) + stringValue(try evaluate(right, query: query)))
        }
    }

    private static func number(_ expr: Expr, query: (String) -> Double) throws -> Double {
        guard case .number(let value) = try evaluate(expr, query: query) else { throw EvalError.invalidType }
        return value
    }

    private static func evaluateFunction(_ name: String, args: [Expr], query: (String) -> Double) throws -> Value {
        switch name {
        case "query":
            guard args.count == 1, case .text(let name) = try evaluate(args[0], query: query) else {
                throw EvalError.invalidArguments
            }
            return .number(query(name))
        case "if":
            guard args.count == 3 else { throw EvalError.invalidArguments }
            let condition = try evaluate(args[0], query: query)
            return try evaluate(try isTruthy(condition) ? args[1] : args[2], query: query)
        case "abs":
            guard args.count == 1 else { throw EvalError.invalidArguments }
            return .number(abs(try number(args[0], query: query)))
        case "round":
            guard args.count == 1 || args.count == 2 else { throw EvalError.invalidArguments }
            let value = try number(args[0], query: query)
            let digits = args.count == 2 ? try number(args[1], query: query) : 0
            let factor = pow(10, digits)
            let result = (value * factor).rounded() / factor
            guard result.isFinite else { throw EvalError.invalidType }
            return .number(result)
        default: throw EvalError.invalidArguments
        }
    }

    private static func isTruthy(_ value: Value) throws -> Bool {
        switch value {
        case .number(let value): return value != 0
        case .text(let value):
            switch value.uppercased() {
            case "TRUE": return true
            case "FALSE", "": return false
            default: throw EvalError.invalidType
            }
        case .boolean(let value): return value
        }
    }

    private static func compare(_ op: String, left: Value, right: Value) throws -> Bool {
        if case .number(let left) = left, case .number(let right) = right {
            return try apply(op, left, right)
        }
        if case .text(let left) = left, case .text(let right) = right {
            let result = left.compare(
                right,
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en"))
            switch op {
            case "=": return result == .orderedSame
            case "<>": return result != .orderedSame
            case ">": return result == .orderedDescending
            case "<": return result == .orderedAscending
            case ">=": return result != .orderedAscending
            case "<=": return result != .orderedDescending
            default: throw EvalError.invalidArguments
            }
        }
        return try apply(op, stringValue(left), stringValue(right))
    }

    private static func apply<T: Comparable>(_ op: String, _ left: T, _ right: T) throws -> Bool {
        switch op {
        case "=": return left == right
        case "<>": return left != right
        case ">": return left > right
        case "<": return left < right
        case ">=": return left >= right
        case "<=": return left <= right
        default: throw EvalError.invalidArguments
        }
    }

    private static func stringValue(_ value: Value) -> String {
        switch value {
        case .text(let value): return value
        case .boolean(let value): return value ? "TRUE" : "FALSE"
        case .number(let value):
            guard value.isFinite else { return "" }
            var result = String(format: "%.12f", locale: Locale(identifier: "en_US_POSIX"), value)
            while result.last == "0" { result.removeLast() }
            if result.last == "." { result.removeLast() }
            return result == "-0" ? "0" : result
        }
    }

    // MARK: - Recursive-descent parser
    //
    //   expression    := concatenation (comparison-op concatenation)*
    //   concatenation := arithmetic ("&" arithmetic)*
    //   arithmetic    := term (("+" | "-") term)*
    //   term          := factor (("*" | "/") factor)*
    //   factor        := NUMBER | STRING | "-" factor | "(" expression ")" | call

    struct Parser {
        private let chars: [Character]
        private var pos = 0

        init(_ input: String) { chars = Array(input) }

        mutating func parseExpression() -> Expr? {
            guard let expr = expression(), atEnd() else { return nil }
            return expr
        }

        private mutating func expression() -> Expr? {
            guard var left = concatenation() else { return nil }
            while let op = comparisonOperator() {
                guard let right = concatenation() else { return nil }
                left = .compare(op, left, right)
            }
            return left
        }

        private mutating func concatenation() -> Expr? {
            guard var left = arithmetic() else { return nil }
            while consume("&") {
                guard let right = arithmetic() else { return nil }
                left = .concat(left, right)
            }
            return left
        }

        private mutating func arithmetic() -> Expr? {
            guard var left = term() else { return nil }
            while let op = peekOperator(["+", "-"]) {
                advance(); guard let right = term() else { return nil }
                left = op == "+" ? .add(left, right) : .sub(left, right)
            }
            return left
        }

        private mutating func term() -> Expr? {
            guard var left = factor() else { return nil }
            while let op = peekOperator(["*", "/"]) {
                advance(); guard let right = factor() else { return nil }
                left = op == "*" ? .mul(left, right) : .div(left, right)
            }
            return left
        }

        private mutating func factor() -> Expr? {
            skipWhitespace(); guard let c = peek() else { return nil }
            if c == "-" {
                advance(); guard let inner = factor() else { return nil }
                return .neg(inner)
            }
            if c == "(" {
                advance(); guard let inner = expression(), consume(")") else { return nil }
                return inner
            }
            if c == "\"" { return string() }
            if c.isNumber || c == "." { return number() }
            if c.isLetter { return functionCall() }
            return nil
        }

        private mutating func number() -> Expr? {
            skipWhitespace()
            var digits = ""
            while let c = peek(), c.isNumber || c == "." {
                digits.append(c); advance()
            }
            return Double(digits).map(Expr.number)
        }

        private mutating func functionCall() -> Expr? {
            skipWhitespace()
            var ident = ""
            while let c = peek(), c.isLetter || c.isNumber || c == "_" {
                ident.append(c); advance()
            }
            guard consume("(") else { return nil }
            var args: [Expr] = []
            if consume(")") { return .function(ident.lowercased(), args) }
            while true {
                guard let arg = expression() else { return nil }
                args.append(arg)
                if consume(")") { break }
                guard consume(",") else { return nil }
            }
            return .function(ident.lowercased(), args)
        }

        private mutating func string() -> Expr? {
            guard consume("\"") else { return nil }
            var value = ""
            while let c = peek(), c != "\"" {
                value.append(c); advance()
            }
            guard consume("\"") else { return nil }
            return .string(value)
        }

        private func peek() -> Character? { pos < chars.count ? chars[pos] : nil }
        private mutating func advance() { pos += 1 }

        private mutating func skipWhitespace() {
            while let c = peek(), c.isWhitespace { advance() }
        }

        private mutating func peekOperator(_ ops: [Character]) -> Character? {
            skipWhitespace(); guard let c = peek(), ops.contains(c) else { return nil }
            return c
        }

        private mutating func comparisonOperator() -> String? {
            skipWhitespace()
            for op in [">=", "<=", "<>", "=", ">", "<"] {
                guard pos + op.count <= chars.count else { continue }
                if String(chars[pos..<(pos + op.count)]) == op {
                    pos += op.count; return op
                }
            }
            return nil
        }

        private mutating func consume(_ character: Character) -> Bool {
            skipWhitespace(); guard peek() == character else { return false }
            advance(); return true
        }

        private mutating func atEnd() -> Bool {
            skipWhitespace()
            return pos >= chars.count
        }
    }
}
