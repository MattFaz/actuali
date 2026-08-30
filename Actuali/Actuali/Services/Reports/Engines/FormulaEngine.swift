import Foundation

/// Native evaluator for Formula card widgets. Actual evaluates Formula cards
/// with HyperFormula; Actuali keeps this evaluator native and read-only.
///
/// The important part for QUERY is that it follows Actual's transaction
/// aggregation semantics: live transactions only, split parents excluded,
/// and children of tombstoned/missing parents ignored.
enum FormulaEngine {

    enum Result: Equatable {
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
        guard let expression = parser.parseExpression() else {
            return .unsupported("This formula isn't supported yet")
        }

        do {
            let value = try evaluate(
                expression,
                meta: meta,
                transactions: transactions,
                today: today,
                context: context
            )
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

    // MARK: - Query evaluation

    private static func queryMatches(
        named name: String,
        meta: FormulaMeta?,
        transactions: [Transaction],
        today: Date,
        context: ConditionsFilter.Context
    ) -> [Transaction] {
        guard let query = meta?.queries?[name] else { return [] }

        // Actual's transaction aggregates operate on leaf transactions rather
        // than split-parent rows. A split parent contains the total and its
        // children contain the individual portions; including both would
        // double-count a split transaction.
        //
        // Children of tombstoned/missing parents are also ignored. Build the
        // set from the supplied report rows so this remains correct even when
        // the caller has loaded both parent and child rows.
        let liveIDs = Set(
            transactions
                .filter { !$0.tombstone }
                .map(\.id)
        )

        var pool = transactions.filter { transaction in
            guard !transaction.tombstone else { return false }
            guard !transaction.isParent else { return false }
            if let parentId = transaction.parentId {
                return liveIDs.contains(parentId)
            }
            return true
        }

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

    private static func querySum(
        named name: String,
        meta: FormulaMeta?,
        transactions: [Transaction],
        today: Date,
        context: ConditionsFilter.Context
    ) -> Double {
        Double(
            queryMatches(
                named: name,
                meta: meta,
                transactions: transactions,
                today: today,
                context: context
            ).reduce(0) { $0 + $1.amount }
        ) / 100
    }

    private static func queryCount(
        named name: String,
        meta: FormulaMeta?,
        transactions: [Transaction],
        today: Date,
        context: ConditionsFilter.Context
    ) -> Double {
        Double(
            queryMatches(
                named: name,
                meta: meta,
                transactions: transactions,
                today: today,
                context: context
            ).count
        )
    }

    private static func ymdInt(from date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return (components.year ?? 0) * 10000
            + (components.month ?? 0) * 100
            + (components.day ?? 0)
    }

    // MARK: - Evaluation

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
        _ expression: Expr,
        meta: FormulaMeta?,
        transactions: [Transaction],
        today: Date,
        context: ConditionsFilter.Context
    ) throws -> Double {
        switch expression {
        case .number(let value):
            return value
        case .string:
            throw EvalError.invalidArgument
        case .add(let left, let right):
            return try evaluate(left, meta: meta, transactions: transactions, today: today, context: context)
                + evaluate(right, meta: meta, transactions: transactions, today: today, context: context)
        case .sub(let left, let right):
            return try evaluate(left, meta: meta, transactions: transactions, today: today, context: context)
                - evaluate(right, meta: meta, transactions: transactions, today: today, context: context)
        case .mul(let left, let right):
            return try evaluate(left, meta: meta, transactions: transactions, today: today, context: context)
                * evaluate(right, meta: meta, transactions: transactions, today: today, context: context)
        case .div(let left, let right):
            let divisor = try evaluate(right, meta: meta, transactions: transactions, today: today, context: context)
            guard abs(divisor) > .ulpOfOne else { throw EvalError.divisionByZero }
            return try evaluate(left, meta: meta, transactions: transactions, today: today, context: context) / divisor
        case .neg(let value):
            return try -evaluate(value, meta: meta, transactions: transactions, today: today, context: context)
        case .compare(let op, let left, let right):
            let lhs = try evaluate(left, meta: meta, transactions: transactions, today: today, context: context)
            let rhs = try evaluate(right, meta: meta, transactions: transactions, today: today, context: context)
            switch op {
            case .equal: return lhs == rhs ? 1 : 0
            case .notEqual: return lhs != rhs ? 1 : 0
            case .less: return lhs < rhs ? 1 : 0
            case .lessOrEqual: return lhs <= rhs ? 1 : 0
            case .greater: return lhs > rhs ? 1 : 0
            case .greaterOrEqual: return lhs >= rhs ? 1 : 0
            }
        case .function(let name, let args):
            return try evaluateFunction(
                name: name.uppercased(),
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
            return try numericArguments(args, meta: meta, transactions: transactions, today: today, context: context).reduce(0, +)

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
            return Double(try numericArguments(args, meta: meta, transactions: transactions, today: today, context: context).count)

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
            return try args.allSatisfy {
                try evaluate($0, meta: meta, transactions: transactions, today: today, context: context) != 0
            } ? 1 : 0

        case "OR":
            guard !args.isEmpty else { throw EvalError.invalidArgument }
            return try args.contains {
                try evaluate($0, meta: meta, transactions: transactions, today: today, context: context) != 0
            } ? 1 : 0

        case "NOT":
            guard args.count == 1 else { throw EvalError.invalidArgument }
            return try evaluate(args[0], meta: meta, transactions: transactions, today: today, context: context) == 0 ? 1 : 0

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

    // MARK: - Parser

    struct Parser {
        private let chars: [Character]
        private var position = 0

        init(_ input: String) {
            chars = Array(input)
        }

        mutating func parseExpression() -> Expr? {
            guard let expression = expression(), atEnd() else { return nil }
            return expression
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
            guard let character = peek() else { return nil }

            if character == "-" {
                advance()
                guard let inner = factor() else { return nil }
                return .neg(inner)
            }

            if character == "(" {
                advance()
                guard let inner = expression(), consume(")") else { return nil }
                return inner
            }

            if character == "\"" {
                return stringLiteral()
            }

            if character.isNumber || character == "." {
                return number()
            }

            if character.isLetter || character == "_" {
                return functionCall()
            }

            return nil
        }

        private mutating func functionCall() -> Expr? {
            skipWhitespace()
            var name = ""
            while let character = peek(), character.isLetter || character.isNumber || character == "_" {
                name.append(character)
                advance()
            }
            guard consume("(") else { return nil }

            var arguments: [Expr] = []
            skipWhitespace()
            if consume(")") {
                return .function(name: name, args: arguments)
            }

            while true {
                guard let argument = expression() else { return nil }
                arguments.append(argument)
                if consume(")") { break }
                guard consume(",") else { return nil }
            }

            return .function(name: name, args: arguments)
        }

        private mutating func stringLiteral() -> Expr? {
            guard consume("\"") else { return nil }
            var value = ""
            while let character = peek() {
                if character == "\"" {
                    advance()
                    return .string(value)
                }
                if character == "\\" {
                    advance()
                    guard let escaped = peek() else { return nil }
                    value.append(escaped)
                    advance()
                } else {
                    value.append(character)
                    advance()
                }
            }
            return nil
        }

        private mutating func number() -> Expr? {
            skipWhitespace()
            var value = ""
            var decimalSeen = false

            while let character = peek() {
                if character.isNumber {
                    value.append(character)
                    advance()
                } else if character == "." && !decimalSeen {
                    decimalSeen = true
                    value.append(character)
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
            guard let character = peek(), operators.contains(character) else { return nil }
            return character
        }

        private mutating func match(_ sequence: [Character]) -> Bool {
            guard position + sequence.count <= chars.count else { return false }
            for (offset, expected) in sequence.enumerated() where chars[position + offset] != expected {
                return false
            }
            position += sequence.count
            return true
        }

        private func peek() -> Character? {
            position < chars.count ? chars[position] : nil
        }

        private mutating func advance() {
            position += 1
        }

        private mutating func skipWhitespace() {
            while let character = peek(), character.isWhitespace {
                advance()
            }
        }

        private mutating func consume(_ character: Character) -> Bool {
            skipWhitespace()
            guard peek() == character else { return false }
            advance()
            return true
        }

        private mutating func atEnd() -> Bool {
            skipWhitespace()
            return position >= chars.count
        }
    }
}
