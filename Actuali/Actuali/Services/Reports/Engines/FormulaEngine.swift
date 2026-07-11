import Foundation

/// Native evaluator for formula-card widgets. Upstream runs formulas through
/// HyperFormula (a full spreadsheet engine); we support the arithmetic subset
/// that covers real-world cards — numbers, query("name") references,
/// + - * /, parentheses, unary minus — and surface anything else as
/// `.unsupported` so the card explains itself instead of guessing.
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
            let value = try evaluate(expr) { name in
                querySum(named: name, meta: meta, transactions: transactions,
                         today: today, context: context)
            }
            return .value(value)
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

    // MARK: - Expression tree

    indirect enum Expr: Equatable {
        case number(Double)
        case query(String)
        case add(Expr, Expr), sub(Expr, Expr), mul(Expr, Expr), div(Expr, Expr)
        case neg(Expr)
    }

    private enum EvalError: Error { case divisionByZero }

    private static func evaluate(_ expr: Expr, query: (String) -> Double) throws -> Double {
        switch expr {
        case .number(let n): return n
        case .query(let name): return query(name)
        case .add(let l, let r): return try evaluate(l, query: query) + evaluate(r, query: query)
        case .sub(let l, let r): return try evaluate(l, query: query) - evaluate(r, query: query)
        case .mul(let l, let r): return try evaluate(l, query: query) * evaluate(r, query: query)
        case .div(let l, let r):
            let divisor = try evaluate(r, query: query)
            guard abs(divisor) > .ulpOfOne else { throw EvalError.divisionByZero }
            return try evaluate(l, query: query) / divisor
        case .neg(let e): return try -evaluate(e, query: query)
        }
    }

    // MARK: - Recursive-descent parser
    //
    //   expression := term (('+' | '-') term)*
    //   term       := factor (('*' | '/') factor)*
    //   factor     := NUMBER | '-' factor | '(' expression ')'
    //               | 'query' '(' STRING ')'
    //
    // Returns nil on anything outside the grammar (IF(...), cell refs, other
    // functions) — the caller reports "unsupported" rather than mis-evaluating.

    struct Parser {
        private let chars: [Character]
        private var pos = 0

        init(_ input: String) { chars = Array(input) }

        mutating func parseExpression() -> Expr? {
            guard let expr = expression(), atEnd() else { return nil }
            return expr
        }

        private mutating func expression() -> Expr? {
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
            if c.isNumber || c == "." {
                return number()
            }
            if c.isLetter {
                return queryCall()
            }
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

        private mutating func queryCall() -> Expr? {
            skipWhitespace()
            var ident = ""
            while let c = peek(), c.isLetter || c.isNumber || c == "_" {
                ident.append(c); advance()
            }
            // `query` is the only supported function; any other identifier
            // (IF, SUM, A1, …) is out of grammar.
            guard ident.lowercased() == "query", consume("(") else { return nil }
            skipWhitespace()
            guard consume("\"") else { return nil }
            var name = ""
            while let c = peek(), c != "\"" { name.append(c); advance() }
            guard consume("\""), consume(")") else { return nil }
            return .query(name)
        }

        // MARK: lexing helpers

        private func peek() -> Character? { pos < chars.count ? chars[pos] : nil }
        private mutating func advance() { pos += 1 }
        private mutating func skipWhitespace() {
            while let c = peek(), c.isWhitespace { advance() }
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
