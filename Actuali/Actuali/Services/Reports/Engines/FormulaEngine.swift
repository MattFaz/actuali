import Foundation

/// Native evaluator for formula-card widgets. Actual evaluates Formula cards
/// with HyperFormula (a full spreadsheet engine); Actuali supports the numeric
/// subset needed by the read-only Formula cards we can receive from Actual.
enum FormulaEngine {

    enum Result: Equatable {
        /// Currency units (upstream integerToAmount: cents / 100).
        case value(Double)
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
        guard let expr = parser.parseExpression() else {
            return .unsupported("This formula isn't supported yet")
        }

        do {
            let value = try evaluate(expr, Env(
                meta: meta,
                transactions: transactions,
                today: today,
                context: context
            ))
            guard value.isFinite else {
                return .unsupported("This formula returned an invalid number")
            }
            return .value(value)
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

    /// `fetchTransactionsForReports()` supplies live leaf rows: it excludes
    /// tombstoned rows, split parents, and children of dead split parents.
    /// Keep QUERY scoped to those rows and avoid duplicating database logic here.
    private static func queryMatches(named name: String, _ env: Env) -> [Transaction] {
        guard let query = env.meta?.queries?[name] else { return [] }

        var pool = env.transactions
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
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
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
            let divisor = try evaluate(right, env)
            guard abs(divisor) > .ulpOfOne else { throw EvalError.divisionByZero }
            return try evaluate(left, env) / divisor
        case .neg(let value):
            return try -evaluate(value, env)
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

    private static func evaluateFunction(name: String, args: [Expr], _ env: Env) throws -> Double {
        switch name {
        case "QUERY":
            guard args.count == 1, let queryName = stringArgument(args[0]) else {
                throw EvalError.invalidArgument
            }
            return querySum(named: queryName, env)

        case "QUERY_COUNT":
            guard args.count == 1, let queryName = stringArgument(args[0]) else {
                throw EvalError.invalidArgument
            }
            return queryCount(named: queryName, env)

        case "SUM":
            return try numericArguments(args, env).reduce(0, +)

        case "AVERAGE":
            let values = try numericArguments(args, env)
            guard !values.isEmpty else { throw EvalError.invalidArgument }
            return values.reduce(0, +) / Double(values.count)

        case "MIN":
            let values = try numericArguments(args, env)
            guard let first = values.first else { throw EvalError.invalidArgument }
            return values.dropFirst().reduce(first, Swift.min)

        case "MAX":
            let values = try numericArguments(args, env)
            guard let first = values.first else { throw EvalError.invalidArgument }
            return values.dropFirst().reduce(first, Swift.max)

        case "PRODUCT":
            let values = try numericArguments(args, env)
            guard !values.isEmpty else { throw EvalError.invalidArgument }
            return values.reduce(1, *)

        case "COUNT":
            return Double(try numericArguments(args, env).count)

        case "ABS":
            guard args.count == 1 else { throw EvalError.invalidArgument }
            return abs(try evaluate(args[0], env))

        case "SQRT":
            guard args.count == 1 else { throw EvalError.invalidArgument }
            return sqrt(try evaluate(args[0], env))

        case "POWER":
            guard args.count == 2 else { throw EvalError.invalidArgument }
            return pow(try evaluate(args[0], env), try evaluate(args[1], env))

        case "ROUND":
            guard args.count == 1 || args.count == 2 else { throw EvalError.invalidArgument }
            let value = try evaluate(args[0], env)
            let digits = args.count == 2 ? Int(try evaluate(args[1], env)) : 0
            let factor = pow(10, Double(digits))
            return (value * factor).rounded() / factor

        case "FLOOR":
            guard args.count == 1 || args.count == 2 else { throw EvalError.invalidArgument }
            let value = try evaluate(args[0], env)
            let significance = args.count == 2 ? try evaluate(args[1], env) : 1
            guard significance != 0 else { throw EvalError.divisionByZero }
            return floor(value / significance) * significance

        case "CEILING":
            guard args.count == 1 || args.count == 2 else { throw EvalError.invalidArgument }
            let value = try evaluate(args[0], env)
            let significance = args.count == 2 ? try evaluate(args[1], env) : 1
            guard significance != 0 else { throw EvalError.divisionByZero }
            return ceil(value / significance) * significance

        case "IF":
            guard args.count == 3 else { throw EvalError.invalidArgument }
            let condition = try evaluate(args[0], env)
            return try evaluate(condition != 0 ? args[1] : args[2], env)

        case "AND":
            guard !args.isEmpty else { throw EvalError.invalidArgument }
            for arg in args where try evaluate(arg, env) == 0 { return 0 }
            return 1

        case "OR":
            guard !args.isEmpty else { throw EvalError.invalidArgument }
            for arg in args where try evaluate(arg, env) != 0 { return 1 }
            return 0

        case "NOT":
            guard args.count == 1 else { throw EvalError.invalidArgument }
            return try evaluate(args[0], env) == 0 ? 1 : 0

        case "PI":
            guard args.isEmpty else { throw EvalError.invalidArgument }
            return Double.pi

        default:
            throw EvalError.invalidFunction
        }
    }

    private static func stringArgument(_ expression: Expr) -> String? {
        guard case .string(let value) = expression else { return nil }
        return value
    }

    private static func numericArguments(_ args: [Expr], _ env: Env) throws -> [Double] {
        try args.map {
            guard case .string = $0 else { return try evaluate($0, env) }
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
            if match(["<", ">"]){ return .notEqual }
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
