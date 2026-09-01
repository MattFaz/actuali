import Foundation

/// Native evaluator for formula-card widgets. Actual evaluates Formula cards
/// with HyperFormula; Actuali keeps this evaluator native and read-only.
enum FormulaEngine {

    enum Result: Equatable {
        /// Currency units. FormulaWidgetView renders these using the budget's
        /// normal currency formatting.
        case value(Double)
        /// A plain numeric result, such as a comparison result.
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
            let result = try evaluate(expression, Env(
                meta: meta,
                transactions: transactions,
                today: today,
                context: context
            ))
            guard result.isFinite else {
                return .unsupported("This formula returned an invalid number")
            }
            if isCurrency(expression) {
                // FormulaWidgetView converts currency to cents before passing
                // it to Int. Check the rounded cents value to keep every
                // reachable Int conversion safe.
                guard abs((result * 100).rounded()) < Double(Int.max) else {
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

    private enum EvalError: Error {
        case divisionByZero
        case invalidFunction
        case invalidArgument
    }

    // MARK: - Queries

    private static func querySum(named name: String, _ env: Env) -> Double {
        guard let query = env.meta?.queries?.first(where: {
            $0.key.caseInsensitiveCompare(name) == .orderedSame
        })?.value else { return 0 }

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

        let cents = pool
            .filter {
                ConditionsFilter.matches(
                    transaction: $0,
                    conditions: query.conditions,
                    op: query.conditionsOp,
                    context: env.context
                )
            }
            .reduce(0) { $0 + $1.amount }
        return Double(cents) / 100
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

    private static func evaluate(_ expression: Expr, _ env: Env) throws -> Double {
        switch expression {
        case .number(let value):
            return value
        case .string:
            throw EvalError.invalidArgument
        case .add(let left, let right):
            return try evaluate(left, env) + evaluate(right, env)
        case .sub(let left, let right):
            return try evaluate(left, env) - evaluate(right, env)
        case .mul(let left, let right):
            return try evaluate(left, env) * evaluate(right, env)
        case .div(let left, let right):
            let lhs = try evaluate(left, env)
            let rhs = try evaluate(right, env)
            guard abs(rhs) > .ulpOfOne else { throw EvalError.divisionByZero }
            return lhs / rhs
        case .neg(let value):
            return -(try evaluate(value, env))
        case .compare(let op, let left, let right):
            let lhs = try evaluate(left, env)
            let rhs = try evaluate(right, env)
            switch op {
            case .equal: return lhs == rhs ? 1 : 0
            case .notEqual: return lhs != rhs ? 1 : 0
            case .less: return lhs < rhs ? 1 : 0
            case .lessOrEqual: return lhs <= rhs ? 1 : 0
            case .greater: return lhs > rhs ? 1 : 0
            case .greaterOrEqual: return lhs >= rhs ? 1 : 0
            }
        case .function(let name, let args):
            return try evaluateFunction(name: name.uppercased(), args: args, env)
        }
    }

    /// Determines the display unit from the complete parsed expression rather
    /// than from whichever conditional branch happens to execute.
    private static func isCurrency(_ expression: Expr) -> Bool {
        switch expression {
        case .number, .string, .compare:
            return false
        case .function(let name, let args):
            return name.uppercased() == "QUERY" || args.contains { isCurrency($0) }
        case .add(let left, let right), .sub(let left, let right), .mul(let left, let right):
            return isCurrency(left) || isCurrency(right)
        case .div(let left, let right):
            return isCurrency(left) && !isCurrency(right)
        case .neg(let inner):
            return isCurrency(inner)
        }
    }

    private static func evaluateFunction(name: String, args: [Expr], _ env: Env) throws -> Double {
        switch name {
        case "QUERY":
            guard args.count == 1, case .string(let queryName) = args[0] else {
                throw EvalError.invalidArgument
            }
            return querySum(named: queryName, env)

        case "SUM":
            guard !args.isEmpty else { throw EvalError.invalidArgument }
            return try args.reduce(0) { total, expression in
                total + (try evaluate(expression, env))
            }

        case "MIN":
            guard !args.isEmpty else { throw EvalError.invalidArgument }
            let values = try args.map { try evaluate($0, env) }
            return values.dropFirst().reduce(values[0]) { Swift.min($0, $1) }

        case "MAX":
            guard !args.isEmpty else { throw EvalError.invalidArgument }
            let values = try args.map { try evaluate($0, env) }
            return values.dropFirst().reduce(values[0]) { Swift.max($0, $1) }

        case "ABS":
            guard args.count == 1 else { throw EvalError.invalidArgument }
            return abs(try evaluate(args[0], env))

        case "IF":
            guard args.count == 3 else { throw EvalError.invalidArgument }
            let condition = try evaluate(args[0], env)
            return try evaluate(condition != 0 ? args[1] : args[2], env)

        default:
            throw EvalError.invalidFunction
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
            if match(["<", ">"]) { return .notEqual }
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
