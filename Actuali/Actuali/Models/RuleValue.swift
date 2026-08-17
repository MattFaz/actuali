import Foundation

/// A JSON value carried by a rule condition or action. Rules live as JSON blobs
/// in the `rules` table, so every value is a JSON primitive — modelling that
/// explicitly instead of `Any?` keeps the model `Equatable` (SwiftUI state) and
/// makes the round trip back out to JSON exact.
enum RuleValue: Equatable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case list([RuleValue])
    case object([String: RuleValue])
    case null

    /// Wrap a value produced by `JSONSerialization`.
    init(json: Any?) {
        switch json {
        case nil, is NSNull:
            self = .null
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            // NSNumber erases Bool; CFBoolean is the only way to tell them apart.
            self = CFGetTypeID(value) == CFBooleanGetTypeID()
                ? .bool(value.boolValue)
                : .number(value.doubleValue)
        case let value as [Any]:
            self = .list(value.map(RuleValue.init(json:)))
        case let value as [String: Any]:
            self = .object(value.mapValues(RuleValue.init(json:)))
        default:
            self = .null
        }
    }

    /// The `JSONSerialization`-compatible representation for writing back.
    /// Whole numbers serialize as integers so amounts round-trip as the cents
    /// upstream wrote (`1050`, not `1050.0`).
    var jsonObject: Any {
        switch self {
        case .string(let value): return value
        case .number(let value):
            // JSON has no NaN or infinity, so these can only arrive from code —
            // but JSONSerialization refuses to encode them, and the whole rule
            // would serialize to "[]".
            guard value.isFinite else { return NSNull() }
            guard value.rounded() == value, abs(value) < 9_007_199_254_740_992 else { return value }
            return Int(value)
        case .bool(let value): return value
        case .list(let items): return items.map(\.jsonObject)
        case .object(let dict): return dict.mapValues(\.jsonObject)
        case .null: return NSNull()
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var listValue: [RuleValue]? {
        if case .list(let items) = self { return items }
        return nil
    }

    /// The `{num1, num2}` payload an `isbetween` condition carries.
    var betweenValue: (num1: Double, num2: Double)? {
        guard case .object(let dict) = self,
              let num1 = dict["num1"]?.numberValue,
              let num2 = dict["num2"]?.numberValue else { return nil }
        return (num1, num2)
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}
