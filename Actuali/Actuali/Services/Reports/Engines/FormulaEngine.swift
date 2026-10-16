import Foundation

/// Native evaluator for formula-card widgets. This intentionally supports a
/// small scalar subset of HyperFormula and reports unsupported formulas rather
/// than guessing how spreadsheet ranges or unsupported functions should behave.
enum FormulaEngine {
    enum Result: Equatable {
        /// Currency units (upstream integerToAmount: cents / 100).
        case value(Double)
        case plain(Double)
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
                matchingTransactions(
                    named: name, meta: meta, transactions: transactions,
                    today: today, context: context
                )
            }
            switch result {
            case .number(let value):
                guard value.isFinite else {
                    return .unsupported("This formula isn't supported yet")
                }
                return .value(value)
            case .plainNumber(let value):
                guard value.isFinite else {
                    return .unsupported("This formula isn't supported yet")
                }
                return .plain(value)
            case .text(let value): return .text(value)
            case .boolean(let value): return .text(value ? "TRUE" : "FALSE")
            }
        } catch EvalError.divisionByZero {
            return .unsupported("Division by zero")
        } catch {
            return .unsupported("This formula isn't supported yet")
        }
    }

    /// Transactions matching a named query's filters and time frame.
    /// Unknown names match no transactions, just as QUERY does.
    private static func matchingTransactions(
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
            let startYMD = ymdInt(from: start), endYMD = ymdInt(from: end)
            pool = pool.filter { $0.date >= startYMD && $0.date <= endYMD }
        }
        return pool.filter {
            ConditionsFilter.matches(
                transaction: $0, conditions: query.conditions,
                op: query.conditionsOp, context: context
            )
        }
    }

    private static func ymdInt(from date: Date) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0)
    }

    indirect enum Expr: Equatable {
        case number(Double), string(String), function(String, [Expr])
        case add(Expr, Expr), sub(Expr, Expr), mul(Expr, Expr), div(Expr, Expr), pow(Expr, Expr)
        case neg(Expr), percent(Expr), compare(String, Expr, Expr), concat(Expr, Expr)
    }

    private enum Value: Equatable {
        case number(Double), plainNumber(Double), text(String), boolean(Bool)
    }

    private enum EvalError: Error {
        case divisionByZero
        case invalidArguments
        case invalidType
        case unsupportedFunction
    }

    private static func finite(_ value: Double, plain: Bool = false) throws -> Value {
        guard value.isFinite else { throw EvalError.invalidType }
        return plain ? .plainNumber(value) : .number(value)
    }

    private static func numericValue(_ value: Value) -> Double? {
        switch value {
        case .number(let number), .plainNumber(let number): number
        case .text, .boolean: nil
        }
    }

    private static func numeric(_ value: Value) throws -> Double {
        guard let number = numericValue(value) else { throw EvalError.invalidType }
        return number
    }

    private static func isPlainNumber(_ value: Value) -> Bool {
        if case .plainNumber = value {
            return true
        }
        return false
    }

    private static func evaluate(_ expr: Expr, matching: (String) -> [Transaction]) throws -> Value {
        switch expr {
        case .number(let number): return .number(number)
        case .string(let value): return .text(value)
        case .function(let name, let args):
            return try evaluateFunction(name, args: args, matching: matching)
        case .add(let left, let right):
            let lhs = try evaluate(left, matching: matching), rhs = try evaluate(right, matching: matching)
            return try finite(numeric(lhs) + numeric(rhs), plain: isPlainNumber(lhs) || isPlainNumber(rhs))
        case .sub(let left, let right):
            let lhs = try evaluate(left, matching: matching), rhs = try evaluate(right, matching: matching)
            return try finite(numeric(lhs) - numeric(rhs), plain: isPlainNumber(lhs) || isPlainNumber(rhs))
        case .mul(let left, let right):
            let lhs = try evaluate(left, matching: matching), rhs = try evaluate(right, matching: matching)
            return try finite(numeric(lhs) * numeric(rhs), plain: isPlainNumber(lhs) || isPlainNumber(rhs))
        case .div(let left, let right):
            let lhs = try evaluate(left, matching: matching), rhs = try evaluate(right, matching: matching)
            let divisor = try numeric(rhs)
            guard divisor != 0 else { throw EvalError.divisionByZero }
            return try finite(numeric(lhs) / divisor, plain: isPlainNumber(lhs) || isPlainNumber(rhs))
        case .pow(let base, let exponent):
            let baseValue = try evaluate(base, matching: matching)
            let exponentValue = try evaluate(exponent, matching: matching)
            let baseNumber = try numeric(baseValue)
            let exponentNumber = try numeric(exponentValue)
            return try finite(
                pow(baseNumber, exponentNumber),
                plain: isPlainNumber(baseValue) || isPlainNumber(exponentValue)
            )
        case .neg(let expression):
            let value = try evaluate(expression, matching: matching)
            return try finite(-numeric(value), plain: isPlainNumber(value))
        case .percent(let expression):
            let value = try evaluate(expression, matching: matching)
            return try finite(numeric(value) / 100, plain: isPlainNumber(value))
        case .compare(let op, let left, let right):
            return try .boolean(compare(
                op,
                left: evaluate(left, matching: matching),
                right: evaluate(right, matching: matching)
            ))
        case .concat(let left, let right):
            return try .text(
                stringValue(evaluate(left, matching: matching))
                    + stringValue(evaluate(right, matching: matching))
            )
        }
    }

    private static func number(_ expr: Expr, matching: (String) -> [Transaction]) throws -> Double {
        try numeric(evaluate(expr, matching: matching))
    }

    private static func evaluateFunction(
        _ name: String, args: [Expr], matching: (String) -> [Transaction]
    ) throws -> Value {
        switch name {
        case "query":
            guard args.count == 1, case .text(let queryName) = try evaluate(args[0], matching: matching) else {
                throw EvalError.invalidArguments
            }
            let cents = matching(queryName).reduce(0) { $0 + $1.amount }
            return .number(Double(cents) / 100)
        case "query_count":
            guard args.count == 1, case .text(let queryName) = try evaluate(args[0], matching: matching) else {
                throw EvalError.invalidArguments
            }
            return .plainNumber(Double(matching(queryName).count))
        case "if":
            guard args.count == 3 else { throw EvalError.invalidArguments }
            let condition = try evaluate(args[0], matching: matching)
            return try evaluate(isTruthy(condition) ? args[1] : args[2], matching: matching)
        case "iferror":
            guard args.count == 2 else { throw EvalError.invalidArguments }
            do {
                return try evaluate(args[0], matching: matching)
            } catch EvalError.unsupportedFunction {
                throw EvalError.unsupportedFunction
            } catch {
                return try evaluate(args[1], matching: matching)
            }
        case "true":
            guard args.isEmpty else { throw EvalError.invalidArguments }
            return .boolean(true)
        case "false":
            guard args.isEmpty else { throw EvalError.invalidArguments }
            return .boolean(false)
        case "not":
            guard args.count == 1 else { throw EvalError.invalidArguments }
            let value = try evaluate(args[0], matching: matching)
            let truth = try isTruthy(value)
            return .boolean(!truth)
        case "and":
            guard !args.isEmpty else { throw EvalError.invalidArguments }
            for arg in args {
                let value = try evaluate(arg, matching: matching)
                if try !isTruthy(value) {
                    return .boolean(false)
                }
            }
            return .boolean(true)
        case "or":
            guard !args.isEmpty else { throw EvalError.invalidArguments }
            for arg in args {
                let value = try evaluate(arg, matching: matching)
                if try isTruthy(value) {
                    return .boolean(true)
                }
            }
            return .boolean(false)
        case "abs":
            guard args.count == 1 else { throw EvalError.invalidArguments }
            let value = try evaluate(args[0], matching: matching)
            return try finite(abs(numeric(value)), plain: isPlainNumber(value))
        case "round", "roundup", "rounddown", "trunc":
            guard args.count == 1 || args.count == 2 else { throw EvalError.invalidArguments }
            let input = try evaluate(args[0], matching: matching)
            let value = try numeric(input)
            let digits = args.count == 2 ? try number(args[1], matching: matching) : 0
            let factor = pow(10, digits)
            let scaled = value * factor
            let nearest = scaled.rounded()
            let exact = abs(scaled - nearest) <= 8 * scaled.ulp ? nearest : scaled
            let rounded = switch name {
            case "round": nearest
            case "roundup": value < 0 ? floor(exact) : ceil(exact)
            default: value < 0 ? ceil(exact) : floor(exact)
            }
            return try finite(rounded / factor, plain: isPlainNumber(input))
        case "sum", "min", "max", "average", "product":
            guard !args.isEmpty else { throw EvalError.invalidArguments }
            let evaluated = try args.map { try evaluate($0, matching: matching) }
            let values = try evaluated.map { try numeric($0) }
            let result = switch name {
            case "sum": values.reduce(0, +)
            case "min": values.min()!
            case "max": values.max()!
            case "average": values.reduce(0, +) / Double(values.count)
            default: values.reduce(1, *)
            }
            return try finite(result, plain: evaluated.contains { isPlainNumber($0) })
        case "mod":
            guard args.count == 2 else { throw EvalError.invalidArguments }
            let value = try evaluate(args[0], matching: matching)
            let divisor = try number(args[1], matching: matching)
            let dividend = try numeric(value)
            guard divisor != 0 else { throw EvalError.divisionByZero }
            return try finite(dividend - divisor * floor(dividend / divisor), plain: isPlainNumber(value))
        case "power":
            guard args.count == 2 else { throw EvalError.invalidArguments }
            let base = try evaluate(args[0], matching: matching)
            let exponent = try number(args[1], matching: matching)
            return try finite(pow(numeric(base), exponent), plain: isPlainNumber(base))
        case "sqrt":
            guard args.count == 1 else { throw EvalError.invalidArguments }
            let value = try evaluate(args[0], matching: matching)
            return try finite(sqrt(numeric(value)), plain: isPlainNumber(value))
        default:
            throw EvalError.unsupportedFunction
        }
    }

    private static func isTruthy(_ value: Value) throws -> Bool {
        switch value {
        case .number(let value), .plainNumber(let value): return value != 0
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
        if let leftNumber = numericValue(left), let rightNumber = numericValue(right) {
            return try apply(op, leftNumber, rightNumber)
        }
        if case .text(let left) = left, case .text(let right) = right {
            let result = left.compare(
                right,
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en")
            )
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
        case .number(let value), .plainNumber(let value):
            guard value.isFinite else { return "" }
            var result = String(format: "%.12f", locale: Locale(identifier: "en_US_POSIX"), value)
            while result.last == "0" {
                result.removeLast()
            }
            if result.last == "." {
                result.removeLast()
            }
            return result == "-0" ? "0" : result
        }
    }

    // MARK: - Recursive-descent parser

    // expression := concatenation (comparison-op concatenation)*
    // concatenation := arithmetic ("&" arithmetic)*
    // arithmetic := term (("+" | "-") term)*
    // term := power (("*" | "/") power)*
    // power := unary ("^" unary)*
    // unary := "-" unary | primary
    // primary := NUMBER | STRING | "(" expression ")" | call, followed by "%"

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
            guard var left = power() else { return nil }
            while let op = peekOperator(["*", "/"]) {
                advance(); guard let right = power() else { return nil }
                left = op == "*" ? .mul(left, right) : .div(left, right)
            }
            return left
        }

        private mutating func power() -> Expr? {
            guard var left = unary() else { return nil }
            while consume("^") {
                guard let right = unary() else { return nil }
                left = .pow(left, right)
            }
            return left
        }

        private mutating func unary() -> Expr? {
            if consume("-") {
                guard let inner = unary() else { return nil }
                return .neg(inner)
            }
            return primary()
        }

        private mutating func primary() -> Expr? {
            skipWhitespace(); guard let c = peek() else { return nil }
            let expression: Expr
            if c == "(" {
                advance(); guard let inner = self.expression(), consume(")") else { return nil }
                expression = inner
            } else if c == "\"" {
                guard let string = string() else { return nil }
                expression = string
            } else if c.isNumber || c == "." {
                guard let number = number() else { return nil }
                expression = number
            } else if c.isLetter {
                guard let call = functionCall() else { return nil }
                expression = call
            } else {
                return nil
            }
            var result = expression
            while consume("%") {
                result = .percent(result)
            }
            return result
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
            if consume(")") {
                return .function(ident.lowercased(), args)
            }
            while true {
                guard let arg = expression() else { return nil }
                args.append(arg)
                if consume(")") {
                    break
                }
                guard consume(",") else { return nil }
            }
            return .function(ident.lowercased(), args)
        }

        private mutating func string() -> Expr? {
            guard consume("\"") else { return nil }
            var value = ""
            while let c = peek() {
                if c == "\"" {
                    advance()
                    if peek() == "\"" {
                        advance()
                        value.append("\"")
                    } else {
                        return .string(value)
                    }
                } else {
                    value.append(c); advance()
                }
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
