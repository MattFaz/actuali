import Foundation

/// Native evaluator for formula-card widgets. Actual evaluates Formula cards
/// with HyperFormula; Actuali keeps this evaluator native and read-only.
///
/// The evaluator intentionally supports the formula syntax currently needed
/// by Actuali's read-only Formula cards, including common HyperFormula-style
/// functions that may be present in synced cards.
enum FormulaEngine {

    enum Result: Equatable {
        /// Currency units. FormulaWidgetView renders these using the budget's
        /// normal currency formatting.
        case value(Double)
        /// A plain numeric result, such as a count or mathematical constant.
        case number(Double)
        case unsupported(String)
    }

    private struct Env {
        let meta: FormulaMeta?
        let transactions: [Transaction]
        let today: Date
        let context: ConditionsFilter.Context
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
        guard let expression = parser.parseExpression() else {
            return .unsupported("This formula isn't supported yet")
        }

        do {
            let (result, kind) = try evaluate(expression, Env(
                meta: meta,
                transactions: transactions,
                today: today,
                context: context
            ))
            guard result.isFinite else {
                return .unsupported("This formula returned an invalid number")
            }
            if case .currency = kind {
                // FormulaWidgetView converts currency to cents before passing
                // it to Int. Check the converted value rather than the Double
                // currency value to keep every reachable Int conversion safe.
                guard abs(result) * 100 < Double(Int.max) else {
                    return .unsupported("This formula returned an invalid number")
                }
                return .value(result)
            }
            return .number(result)
        } catch EvalError.divisionByZero {
            return .unsupported("Division by zero")
        } catch {
            return .unsupported("This formula isn't supported yet")
        }
    }

    private enum ValueKind {
        case currency
        case number
    }

    private enum EvalError: Error {
        case divisionByZero
        case invalidFunction
        case invalidArgument
    }

    // MARK: - Queries

    private static func queryMatches(named name: String, _ env: Env) -> [Transaction] {
        guard let query = env.meta?.queries?[name] else { return [] }

        // Keep the same safety boundary as the other report engines. Report
        // callers normally provide leaf rows already, but QUERY still ignores
        // deleted transactions and split-parent rows if a broader set is passed.
        var pool = env.transactions.filter { !$0.tombstone && !$0.isParent }

        if let timeFrame = query.timeFrame, timeFrame.mode != nil {
            let (start, end) = TimeFrame.resolve(timeFrame, asOf: env.today)
            let startYMD = ymdInt(from: start)
            let endYMD = ymdInt(from: end)
            pool = pool.filter { $0.date >= startYMD && $0.date <= endYMD }
        }

        return pool.filter {
            ConditionsFilter.matches(
                transaction: $0,
                conditions: query.conditions,
                op: query.conditionsOp,
                context: env.context
            )
        }
    }

    private static func querySum(named name: String, _ env: Env) -> Double {
        Double(queryMatches(named: name, env).reduce(0) { $0 + $1.amount }) / 100
    }

    private static func queryCount(named name: String, _ env: Env) -> Double {
        Double(queryMatches(named: name, env).count)
    }

    private static func ymdInt(from date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return (components.year ?? 0) * 10000
            + (components.month ?? 0) * 100
            + (components.day ?? 0)
    }

    // MARK: - Expression tree

    indirect enum Expr: Equatable {
        case number(Double)
        case string(String)
        case function(name: String, args: [Expr])
        case add(Expr, Expr)
        case sub(Expr, Expr)
        case mul(Expr, Expr)
        case div(Expr, Expr)
        case neg(Expr)
        case compare(CompareOp, Expr, Expr)
    }

    enum CompareOp: Equatable {
        case equal
        case notEqual
        case less
        case lessOrEqual
        case greater
        case greaterOrEqual
    }

    private static func evaluate(_ expression: Expr, _ env: Env) throws -> (Double, ValueKind) {
        switch expression {
        case .number(let value):
            // Preserve the pre-FormulaEngine behavior: literal arithmetic is
            // rendered as currency unless a function explicitly produces a
            // dimensionless result such as a count or constant.
            return (value, .currency)
        case .string:
            throw EvalError.invalidArgument
        case .add(let left, let right):
            return try arithmetic(left, right, env) { $0 + $1 }
        case .sub(let left, let right):
            return try arithmetic(left, right, env) { $0 - $1 }
        case .mul(let left, let right):
            return try arithmetic(left, right, env) { $0 * $1 }
        case .div(let left, let right):
            let lhs = try evaluate(left, env)
            let rhs = try evaluate(right, env)
            guard abs(rhs.0) > .ulpOfOne else { throw EvalError.divisionByZero }
            let kind: ValueKind = lhs.1 == .currency && rhs.1 != .currency ? .currency : .number
            return (lhs.0 / rhs.0, kind)
        case .neg(let value):
            let result = try evaluate(value, env)
            return (-result.0, result.1)
        case .compare(let op, let left, let right):
            let lhs = try evaluate(left, env).0
            let rhs = try evaluate(right, env).0
            let result: Bool
            switch op {
            case .equal: result = lhs == rhs
            case .notEqual: result = lhs != rhs
            case .less: result = lhs < rhs
            case .lessOrEqual: result = lhs <= rhs
            case .greater: result = lhs > rhs
            case .greaterOrEqual: result = lhs >= rhs
            }
            return (result ? 1 : 0, .number)
        case .function(let name, let args):
            return try evaluateFunction(name: name.uppercased(), args: args, env)
        }
    }

    private static func arithmetic(
        _ left: Expr,
        _ right: Expr,
        _ env: Env,
        operation: (Double, Double) -> Double
    ) throws -> (Double, ValueKind) {
        let lhs = try evaluate(left, env)
        let rhs = try evaluate(right, env)
        let kind: ValueKind = lhs.1 == .currency || rhs.1 == .currency ? .currency : .number
        return (operation(lhs.0, rhs.0), kind)
    }

    private static func evaluateFunction(name: String, args: [Expr], _ env: Env) throws -> (Double, ValueKind) {
        switch name {
        case "QUERY":
            guard args.count == 1, let queryName = stringArgument(args[0]) else {
                throw EvalError.invalidArgument
            }
            return (querySum(named: queryName, env), .currency)

        case "QUERY_COUNT":
            guard args.count == 1, let queryName = stringArgument(args[0]) else {
                throw EvalError.invalidArgument
            }
            return (queryCount(named: queryName, env), .number)

        case "SUM":
            guard !args.isEmpty else { throw EvalError.invalidArgument }
            return try numericArguments(args, env).reduce((0, .number)) { total, next in
                let kind: ValueKind = total.1 == .currency || next.1 == .currency ? .currency : .number
                return (total.0 + next.0, kind)
            }

        case "AVERAGE":
            let values = try numericArguments(args, env)
            guard !values.isEmpty else { throw EvalError.invalidArgument }
            let total = values.reduce(0) { $0 + $1.0 }
            let hasCurrency = values.contains { $0.1 == .currency }
            return (total / Double(values.count), hasCurrency ? .currency : .number)

        case "MIN":
            let values = try numericArguments(args, env)
            guard let first = values.first else { throw EvalError.invalidArgument }
            let result = values.dropFirst().reduce(first.0) { Swift.min($0, $1.0) }
            return (result, values.contains { $0.1 == .currency } ? .currency : .number)

        case "MAX":
            let values = try numericArguments(args, env)
            guard let first = values.first else { throw EvalError.invalidArgument }
            let result = values.dropFirst().reduce(first.0) { Swift.max($0, $1.0) }
            return (result, values.contains { $0.1 == .currency } ? .currency : .number)

        case "PRODUCT":
            let values = try numericArguments(args, env)
            guard !values.isEmpty else { throw EvalError.invalidArgument }
            let result = values.reduce(1) { $0 * $1.0 }
            return (result, values.contains { $0.1 == .currency } ? .currency : .number)

        case "COUNT":
            // With this grammar, COUNT receives scalar arguments rather than
            // cell ranges. Counting numeric arguments matches that model;
            // QUERY_COUNT is available when transaction count is required.
            return (Double(try numericArguments(args, env).count), .number)

        case "ABS":
            guard args.count == 1 else { throw EvalError.invalidArgument }
            let value = try evaluate(args[0], env)
            return (abs(value.0), value.1)

        case "SQRT":
            guard args.count == 1 else { throw EvalError.invalidArgument }
            let value = try evaluate(args[0], env)
            return (sqrt(value.0), .number)

        case "POWER":
            guard args.count == 2 else { throw EvalError.invalidArgument }
            let base = try evaluate(args[0], env)
            let exponent = try evaluate(args[1], env)
            return (pow(base.0, exponent.0), .number)

        case "ROUND":
            guard args.count == 1 || args.count == 2 else { throw EvalError.invalidArgument }
            let value = try evaluate(args[0], env)
            var digits = 0
            if args.count == 2 {
                let raw = try evaluate(args[1], env).0
                let truncated = raw.rounded(.towardZero)
                guard truncated.isFinite, let exact = Int(exactly: truncated) else {
                    throw EvalError.invalidArgument
                }
                digits = exact
            }
            let factor = pow(10, Double(digits))
            guard factor.isFinite, abs(factor) > .ulpOfOne else {
                throw EvalError.invalidArgument
            }
            return ((value.0 * factor).rounded() / factor, value.1)

        case "FLOOR":
            guard args.count == 1 || args.count == 2 else { throw EvalError.invalidArgument }
            let value = try evaluate(args[0], env)
            let significance = args.count == 2 ? try evaluate(args[1], env).0 : 1
            guard significance.isFinite, significance != 0 else { throw EvalError.invalidArgument }
            return (floor(value.0 / significance) * significance, value.1)

        case "CEILING":
            guard args.count == 1 || args.count == 2 else { throw EvalError.invalidArgument }
            let value = try evaluate(args[0], env)
            let significance = args.count == 2 ? try evaluate(args[1], env).0 : 1
            guard significance.isFinite, significance != 0 else { throw EvalError.invalidArgument }
            return (ceil(value.0 / significance) * significance, value.1)

        case "IF":
            guard args.count == 3 else { throw EvalError.invalidArgument }
            let condition = try evaluate(args[0], env).0
            return try evaluate(condition != 0 ? args[1] : args[2], env)

        case "AND":
            guard !args.isEmpty else { throw EvalError.invalidArgument }
            for arg in args where try evaluate(arg, env).0 == 0 {
                return (0, .number)
            }
            return (1, .number)

        case "OR":
            guard !args.isEmpty else { throw EvalError.invalidArgument }
            for arg in args where try evaluate(arg, env).0 != 0 {
                return (1, .number)
            }
            return (0, .number)

        case "NOT":
            guard args.count == 1 else { throw EvalError.invalidArgument }
            return (try evaluate(args[0], env).0 == 0 ? 1 : 0, .number)

        case "PI":
            guard args.isEmpty else { throw EvalError.invalidArgument }
            return (Double.pi, .number)

        default:
            throw EvalError.invalidFunction
        }
    }

    private static func stringArgument(_ expression: Expr) -> String? {
        guard case .string(let value) = expression else { return nil }
        return value
    }

    private static func numericArguments(_ args: [Expr], _ env: Env) throws -> [(Double, ValueKind)] {
        try args.map { expression in
            guard case .string = expression else {
                return try evaluate(expression, env)
            }
            throw EvalError.invalidArgument
        }
    }

    // MARK: - Recursive-descent parser

    struct Parser {
        private let chars: [Character]
        private var pos = 0

        init(_ input: String) { chars = Array(input) }

        mutating func parseExpression() -> Expr? {
            guard let expr = expression(), atEnd() else { return nil }
            return expr
        }

        private mutating func expression() -> Expr? {
            guard var left = additive() else { return nil }
            skipWhitespace()
            if let op = comparisonOperator() {
                guard let right = additive() else { return nil }
                left = .compare(op, left, right)
            }
            return left
        }

        private mutating func additive() -> Expr? {
            guard var left = term() else { return nil }
            while let op = peekOperator(["+", "-"]) {
                advance()
                guard let right = term() else { return nil }
                left = op == "+" ? .add(left, right) : .sub(left, right)
            }
            return left
        }

        private mutating func term() -> Expr? {
            guard var left = factor() else { return nil }
            while let op = peekOperator(["*", "/"]) {
                advance()
                guard let right = factor() else { return nil }
                left = op == "*" ? .mul(left, right) : .div(left, right)
            }
            return left
        }

        private mutating func factor() -> Expr? {
            skipWhitespace()
            guard let c = peek() else { return nil }
            if c == "-" {
                advance()
                guard let inner = factor() else { return nil }
                return .neg(inner)
            }
            if c == "(" {
                advance()
                guard let inner = expression(), consume(")") else { return nil }
                return inner
            }
            if c == "\"" { return stringLiteral() }
            if c.isNumber || c == "." { return number() }
            if c.isLetter || c == "_" { return functionCall() }
            return nil
        }

        private mutating func functionCall() -> Expr? {
            skipWhitespace()
            var name = ""
            while let c = peek(), c.isLetter || c.isNumber || c == "_" {
                name.append(c)
                advance()
            }
            guard consume("(") else { return nil }
            var args: [Expr] = []
            skipWhitespace()
            if consume(")") { return .function(name: name, args: args) }
            while true {
                guard let arg = expression() else { return nil }
                args.append(arg)
                if consume(")") { break }
                guard consume(",") else { return nil }
            }
            return .function(name: name, args: args)
        }

        private mutating func stringLiteral() -> Expr? {
            guard consume("\"") else { return nil }
            var value = ""
            while let c = peek() {
                if c == "\"" {
                    advance()
                    return .string(value)
                }
                if c == "\\" {
                    advance()
                    guard let escaped = peek() else { return nil }
                    value.append(escaped)
                    advance()
                } else {
                    value.append(c)
                    advance()
                }
            }
            return nil
        }

        private mutating func number() -> Expr? {
            skipWhitespace()
            var value = ""
            var decimalSeen = false
            while let c = peek() {
                if c.isNumber {
                    value.append(c)
                    advance()
                } else if c == "." && !decimalSeen {
                    decimalSeen = true
                    value.append(c)
                    advance()
                } else {
                    break
                }
            }
            return Double(value).map(Expr.number)
        }

        private mutating func comparisonOperator() -> CompareOp? {
            skipWhitespace()
            if match(["<", "="]) { return .lessOrEqual }
            if match([">", "="]) { return .greaterOrEqual }
            if match(["<", ">"] ) { return .notEqual }
            if match(["="]) { return .equal }
            if match(["<"]) { return .less }
            if match([">"]) { return .greater }
            return nil
        }

        private mutating func peekOperator(_ operators: [Character]) -> Character? {
            skipWhitespace()
            guard let c = peek(), operators.contains(c) else { return nil }
            return c
        }

        private mutating func match(_ sequence: [Character]) -> Bool {
            guard pos + sequence.count <= chars.count else { return false }
            for (offset, expected) in sequence.enumerated() where chars[pos + offset] != expected {
                return false
            }
            pos += sequence.count
            return true
        }

        private func peek() -> Character? { pos < chars.count ? chars[pos] : nil }
        private mutating func advance() { pos += 1 }

        private mutating func skipWhitespace() {
            while let c = peek(), c.isWhitespace { advance() }
        }

        private mutating func consume(_ c: Character) -> Bool {
            skipWhitespace()
            guard peek() == c else { return false }
            advance()
            return true
        }

        private mutating func atEnd() -> Bool {
            skipWhitespace()
            return pos >= chars.count
        }
    }
}
