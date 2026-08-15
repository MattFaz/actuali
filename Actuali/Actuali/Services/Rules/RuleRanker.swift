import Foundation
import os

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "RuleRanker")

/// Port of loot-core `rankRules` (server/rules/rule-utils.ts). Rules run
/// `pre` → default → `post`, and within a stage in *ascending* score order so
/// the most specific rule applies last and wins. Ties break on id, so every
/// client orders an identical rule set identically.
enum RuleRanker {

    private static let opScores: [String: Int] = [
        "is": 10, "isNot": 10,
        "oneOf": 9, "notOneOf": 9,
        "isapprox": 5, "isbetween": 5,
        "gt": 1, "gte": 1, "lt": 1, "lte": 1,
        "contains": 0, "doesNotContain": 0, "matches": 0,
        "hasTags": 0, "hasAnyTag": 0,
        "onBudget": 0, "offBudget": 0
    ]

    private static let doublingOps: Set<String> = ["is", "isNot", "isapprox", "oneOf", "notOneOf"]

    static func score(_ rule: Rule) -> Int {
        var total = 0
        for condition in rule.conditions {
            guard let score = opScores[condition.op] else {
                logger.debug("Found invalid operation while ranking: \(condition.op, privacy: .public)")
                return 0
            }
            total += score
        }
        // A rule made purely of exact-match conditions is twice as specific.
        if !rule.conditions.isEmpty, rule.conditions.allSatisfy({ doublingOps.contains($0.op) }) {
            return total * 2
        }
        return total
    }

    static func rank(_ rules: [Rule]) -> [Rule] {
        // Score once per rule, not once per comparison — upstream keeps the same
        // scores map for the same reason.
        var scores: [String: Int] = [:]
        for rule in rules where scores[rule.id] == nil {
            scores[rule.id] = score(rule)
        }

        return Rule.Stage.allCases.flatMap { stage in
            rules
                .filter { $0.stage == stage }
                .sorted { lhs, rhs in
                    let left = scores[lhs.id] ?? 0
                    let right = scores[rhs.id] ?? 0
                    return left == right ? lhs.id < rhs.id : left < right
                }
        }
    }
}
