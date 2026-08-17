import Testing
@testable import Actuali

/// Port fidelity for `rankRules` (loot-core server/rules/rule-utils.ts). Order
/// decides which of two matching rules wins, so the score table is behaviour,
/// not an implementation detail.
struct RuleRankerTests {

    private func rule(id: String, stage: Rule.Stage = .default, ops: [String]) -> Rule {
        Rule(
            id: id,
            stage: stage,
            conditionsOp: .and,
            conditions: ops.map { .init(op: $0, field: "notes", value: .string("x"), options: nil) },
            actions: [.init(op: "set", field: "category", value: .string("cat"), options: nil)]
        )
    }

    @Test func scoresMatchUpstreamTable() {
        #expect(RuleRanker.score(rule(id: "r", ops: ["contains"])) == 0)
        #expect(RuleRanker.score(rule(id: "r", ops: ["gt"])) == 1)
        // All-exact conditions double: is(10) + is(10) = 20, doubled to 40.
        #expect(RuleRanker.score(rule(id: "r", ops: ["is", "is"])) == 40)
        // A single non-exact condition cancels the doubling: 10 + 0.
        #expect(RuleRanker.score(rule(id: "r", ops: ["is", "contains"])) == 10)
    }

    /// Upstream's reducer returns 0 for an unknown operator, resetting the
    /// running total — but conditions after it still accumulate.
    @Test func unknownOperatorResetsScoreAndKeepsAccumulating() {
        #expect(RuleRanker.score(rule(id: "r", ops: ["is", "bogus"])) == 0)
        #expect(RuleRanker.score(rule(id: "r", ops: ["bogus", "is", "gt"])) == 11)
    }

    @Test func ordersByStageThenScoreThenId() {
        let ranked = RuleRanker.rank([
            rule(id: "post", stage: .post, ops: ["is"]),
            rule(id: "b-broad", ops: ["contains"]),
            rule(id: "a-broad", ops: ["contains"]),
            rule(id: "exact", ops: ["is"]),
            rule(id: "pre", stage: .pre, ops: ["contains"])
        ])

        // pre first; inside default, equal scores tie-break on id, then the
        // higher-scoring exact rule runs last so it wins; post last of all.
        #expect(ranked.map(\.id) == ["pre", "a-broad", "b-broad", "exact", "post"])
    }

    @Test func rankingIsStableForIdenticalInput() {
        let rules = [rule(id: "b", ops: ["is"]), rule(id: "a", ops: ["is"])]
        #expect(RuleRanker.rank(rules).map(\.id) == RuleRanker.rank(rules.reversed()).map(\.id))
    }
}
