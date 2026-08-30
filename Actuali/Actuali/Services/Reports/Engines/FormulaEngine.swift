import Foundation

/// Native evaluator for formula-card widgets. Actual evaluates Formula cards
/// with HyperFormula. Actuali intentionally keeps this native and read-only,
/// but supports the common numeric subset needed to render Formula cards that
/// were created in the Actual Budget web app: arithmetic, comparisons,
/// QUERY/QUERY_COUNT, common aggregate/math functions, and IF/AND/OR/NOT.
enum FormulaEngine {

    enum Result: Equatable {
        /// Currency units (upstream integerToAmount: cents / 100).
        case value(Double)
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
            let value = try evaluate(expr, meta: meta, transactions: transactions,
                                     today: today, context: context)
            guard value.isFinite else {
                return .unsupported("This formula returned an invalid number")
            }
            return .value(value)
        } catch EvalError.divisionByZero {
            return .unsupported("Division by zero")
        } catch EvalError.invalidFunction {
            return .unsupported("This formula isn't supported yet")
        } catch {
            return .unsupported("This formula isn't supported yet")
        }
    }

    private enum EvalError: Error {
        case divisionByZero
        case invalidFunction
        case invalidArgument
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
        queryMatches(named: name, meta: meta, transactions: transactions, today: today, context: context)
            .reduce(0) { $0 + $1.amount }
            / 100
    }

    private static func queryCount(
        named name: String,
        meta: FormulaMeta?,
        transactions: [Transaction],
        today: Date,
        context: ConditionsFilter.Context
    ) -> Double {
        Double(queryMatches(named: name, meta: meta, transactions: transactions, today: today, context: context).count)
    }

    private static func queryMatches(
        named name: String,
        meta: FormulaMeta?,
        transactions: [Transaction],
        today: Date,
        context: ConditionsFilter.Context
    ) -> [Transaction] {
        guard let query = meta?.queries?[name] else { return [] }

        var pool = transactions.filter { !$0.tombstone }
        if let timeFrame = query.timeFrame, timeFrame.mode != nil {
            let (start, end) = TimeFrame.resolve(timeFrame, asOf: today)
            let startYMD = ymdInt(from: start)
            let endYMD = ymdInt(from: end)
            pool = pool.filter { $0.date >= startYMD && $0.date <= endYMD }
        }

        return pool.filter {
            ConditionsFilter.matches(
                transaction: $0,
                conditions: query.conditions,
                op: query.conditionsOp,
                context: context
            )
        }
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

    private static func evaluate(
        _ expr: Expr,
        meta: FormulaMeta?,
        transactions: [Transaction],
        today: Date,
        context: ConditionsFilter.Context
    ) throws -> Double {
        switch expr {
        case .number(let n):
            return n
        case .string:
            throw EvalError.invalidArgument
        case .add(let l, let r):
            return try evaluate(l, meta: meta, transactions: transactions, today: today, context: context)
                + evaluate(r, meta: meta, transactions: transactions, today: today, context: context)
        case .sub(let l, let r):
            return try evaluate(l, meta: meta, transactions: transactions, today: today, context: context)
                - evaluate(r, meta: meta, transactions: transactions, today: today, context: context)
        case .mul(let l, let r):
            return try evaluate(l, meta: meta, transactions: transactions, today: today, context: context)
                * evaluate(r, meta: meta, transactions: transactions, today: today, context: context)
        case .div(let l, let r):
            let divisor = try evaluate(r, meta: meta, transactions: transactions, today: today, context: context)
            guard abs(divisor) > .ulpOfOne else { throw EvalError.divisionByZero }
            return try evaluate(l, meta: meta, transactions: transactions, today: today, context: context) / divisor
        case .neg(let e):
            return try -evaluate(e, meta: meta, transactions: transactions, today: today, context: context)
        case .compare(let op, let l, let r):
            let left = try evaluate(l, meta: meta, transactions: transactions, today: today, context: context)
            let right = try evaluate(r, meta: meta, transactions: transactions, today: today, context: context)
            switch op {
            case .equal: return left == right ? 1 : 0
            case .notEqual: return left != right ? 1 : 0
            case .less: return left < right ? 1 : 0
            case .lessOrEqual: return left <= right ? 1 : 0
            case .greater: return left > right ? 1 : 0
            case .greaterOrEqual: return left >= right ? 1 : 0
            }
        case .function(let rawName, let args):
            return try evaluateFunction(
                name: rawName.uppercased(),
                args: args,
                meta: meta,
                transactions: transactions,
                today: today,
                context: context
            )
        }
    }

    private static func evaluateFunction(
        name: String,
        args: [Expr],
        meta: FormulaMeta?,
        transactions: [Transaction],
        today: Date,
        context: ConditionsFilter.Context
    ) throws -> Double {
        switch name {
        case "QUERY":
            guard args.count == 1, let queryName = stringArgument(args[0]) else {
                throw EvalError.invalidArgument
            }
            return querySum(named: queryName, meta: meta, transactions: transactions, today: today, context: context)

        case "QUERY_COUNT":
            guard args.count == 1, let queryName = stringArgument(args[0]) else {
                throw EvalError.invalidArgument
            }
            return queryCount(named: queryName, meta: meta, transactions: transactions, today: today, context: context)

        case "SUM":
            return try numericArguments(args, meta: meta, transactions: transactions, today: today, context: context)
                .reduce(0, +)

        case "AVERAGE":
            let values = try numericArguments(args, meta: meta, transactions: transactions, today: today, context: context)
            guard !values.isEmpty else { throw EvalError.invalidArgument }
            return values.reduce(0, +) / Double(values.count)

        case "MIN":
            let values = try numericArguments(args, meta: meta, transactions: transactions, today: today, context: context)
            guard let first = values.first else { throw EvalError.invalidArgument }
            return values.dropFirst().reduce(first, Swift.min)

        case "MAX":
            let values = try numericArguments(args, meta: meta, transactions: transactions, today: today, context: context)
            guard let first = values.first else { throw EvalError.invalidArgument }
            return values.dropFirst().reduce(first, Swift.max)

        case "PRODUCT":
            let values = try numericArguments(args, meta: meta, transactions: transactions, today: today, context: context)
            guard !values.isEmpty else { throw EvalError.invalidArgument }
            return values.reduce(1, *)

        case "COUNT":
            return Double(
                try numericArguments(args, meta: meta, transactions: transactions, today: today, context: context).count
            )

        case "ABS":
            guard args.count == 1 else { throw EvalError.invalidArgument }
            return abs(try evaluate(args[0], meta: meta, transactions: transactions, today: today, context: context))

        case "SQRT":
            guard args.count == 1 else { throw EvalError.invalidArgument }
            return sqrt(try evaluate(args[0], meta: meta, transactions: transactions, today: today, context: context))

        case "POWER":
            guard args.count == 2 else { throw EvalError.invalidArgument }
            let base = try evaluate(args[0], meta: meta, transactions: transactions, today: today, context: context)
            let exponent = try evaluate(args[1], meta: meta, transactions: transactions, today: today, context: context)
            return pow(base, exponent)

        case "ROUND":
            guard args.count == 1 || args.count == 2 else { throw EvalError.invalidArgument }
            let number = try evaluate(args[0], meta: meta, transactions: transactions, today: today, context: context)
            let digits = args.count == 2
                ? Int(try evaluate(args[1], meta: meta, transactions: transactions, today: today, context: context))
                : 0
            let factor = pow(10, Double(digits))
            return (number * factor).rounded() / factor

        case "FLOOR":
            guard args.count == 1 || args.count == 2 else { throw EvalError.invalidArgument }
            let number = try evaluate(args[0], meta: meta, transactions: transactions, today: today, context: context)
            let significance = args.count == 2
                ? try evaluate(args[1], meta: meta, transactions: transactions, today: today, context: context)
                : 1
            guard significance != 0 else { throw EvalError.divisionByZero }
            return floor(number / significance) * significance

        case "CEILING":
            guard args.count == 1 || args.count == 2 else { throw EvalError.invalidArgument }
            let number = try evaluate(args[0], meta: meta, transactions: transactions, today: today, context: context)
            let significance = args.count == 2
                ? try evaluate(args[1], meta: meta, transactions: transactions, today: today, context: context)
                : 1
            guard significance != 0 else { throw EvalError.divisionByZero }
            return ceil(number / significance) * significance

        case "IF":
            guard args.count == 3 else { throw EvalError.invalidArgument }
            let condition = try evaluate(args[0], meta: meta, transactions: transactions, today: today, context: context)
            return try evaluate(
                condition != 0 ? args[1] : args[2],
                meta: meta,
                transactions: transactions,
                today: today,
                context: context
            )

        case "AND":
            guard !args.isEmpty else { throw EvalError.invalidArgument }
            let values = try args.map {
                try evaluate($0, meta: meta, transactions: transactions, today: today, context: context)
            }
            return values.allSatisfy { $0 != 0 } ? 1 : 0

        case "OR":
            guard !args.isEmpty else { throw EvalError.invalidArgument }
            let values = try args.map {
                try evaluate($0, meta: meta, transactions: transactions, today: today, context: context)
            }
            return values.contains { $0 != 0 } ? 1 : 0

        case "NOT":
            guard args.count == 1 else { throw EvalError.invalidArgument }
            let value = try evaluate(args[0], meta: meta, transactions: transactions, today: today, context: context)
            return value == 0 ? 1 : 0

        case "PI":
            guard args.isEmpty else { throw EvalError.invalidArgument }
            return Double.pi

        default:
            throw EvalError.invalidFunction
        }
    }

    private static func stringArgument(_ expr: Expr) -> String? {
        guard case .string(let value) = expr else { return nil }
        return value
    }

    private static func numericArguments(
        _ args: [Expr],
        meta: FormulaMeta?,
        transactions: [Transaction],
        today: Date,
        context: ConditionsFilter.Context
    ) throws -> [Double] {
        try args.map {
            guard case .string = $0 else {
                return try evaluate($0, meta: meta, transactions: transactions, today: today, context: context)
            }
            throw EvalError.invalidArgument
        }
    }

    // MARK: - Recursive-descent parser
    //
    //   expression := additive (comparison additive)?
    //   additive   := term (('+' | '-') term)*
    //   term       := factor (('*' | '/') factor)*
    //   factor     := NUMBER | STRING | '-' factor | '(' expression ')'
    //               | IDENTIFIER '(' comma-separated expressions ')'
    //
    // This deliberately does not implement cell ranges or budget-specific
    // functions yet. Unsupported functions become a visible read-only error.
    struct Parser {
        private let chars: [Character]
        private var pos = 0

        init(_ input: String) {
            chars = Array(input)
        }

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

            if c == "\"" {
                return stringLiteral()
            }

            if c.isNumber || c == "." {
                return number()
            }

            if c.isLetter || c == "_" {
                return functionCall()
            }

            return nil
        }

        private mutating func number() -> Expr? {
            skipWhitespace()
            var digits = ""
            var decimalSeen = false
            while let c = peek() {
                if c.isNumber {
                    digits.append(c)
                    advance()
                } else if c == "." && !decimalSeen {
                    decimalSeen = true
                    digits.append(c)
                    advance()
                } else {
                    break
                }
            }
            return Double(digits).map(Expr.number)
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
                    switch escaped {
                    case "\"": value.append("\"")
                    case "\\": value.append("\\")
                    case "n": value.append("\n")
                    case "r": value.append("\r")
                    case "t": value.append("\t")
                    default: value.append(escaped)
                    }
                    advance()
                } else {
                    value.append(c)
                    advance()
                }
            }
            return nil
        }

        private mutating func functionCall() -> Expr? {
            skipWhitespace()
            var ident = ""
            while let c = peek(), c.isLetter || c.isNumber || c == "_" {
                ident.append(c)
                advance()
            }
            guard consume("(") else { return nil }

            var args: [Expr] = []
            skipWhitespace()
            if consume(")") {
                return .function(name: ident, args: args)
            }

            while true {
                guard let arg = expression() else { return nil }
                args.append(arg)
                if consume(")") {
                    return .function(name: ident, args: args)
                }
                guard consume(",") else { return nil }
            }
        }

        private mutating func comparisonOperator() -> CompareOp? {
            skipWhitespace()
            if consume("=") { return .equal }
            if consume("<") {
                if consume(">") { return .notEqual }
                if consume("=") { return .lessOrEqual }
                return .less
            }
            if consume(">") {
                if consume("=") { return .greaterOrEqual }
                return .greater
            }
            return nil
        }

        private func peek() -> Character? {
            pos < chars.count ? chars[pos] : nil
        }

        private mutating func advance() {
            pos += 1
        }

        private mutating func skipWhitespace() {
            while let c = peek(), c.isWhitespace {
                advance()
            }
        }

        private mutating func peekOperator(_ ops: [Character]) -> Character? {
            skipWhitespace()
            guard let c = peek(), ops.contains(c) else { return nil }
            return c
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
