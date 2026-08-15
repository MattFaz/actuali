import Testing
@testable import Actuali

/// Rule validation, mirroring upstream `rule-validate` (loot-core
/// server/rules/app.ts): a rule the editor accepts must be one the engine can
/// actually run.
@MainActor
struct BudgetStoreRulesTests {

    private func rule(
        conditions: [Rule.Condition],
        actions: [Rule.Action] = [.init(op: "set", field: "category",
                                        value: .string("cat-1"), options: nil)]
    ) -> Rule {
        Rule(id: "r-1", stage: .default, conditionsOp: .and,
             conditions: conditions, actions: actions)
    }

    @Test func acceptsAWellFormedRule() throws {
        try BudgetStore.validate(rule(conditions: [
            .init(op: "contains", field: "imported_payee", value: .string("woolworths"), options: nil)
        ]))
    }

    @Test func rejectsRuleWithoutConditions() {
        #expect(throws: BudgetStoreError.ruleNeedsCondition) {
            try BudgetStore.validate(rule(conditions: []))
        }
    }

    @Test func rejectsRuleWithoutActions() {
        #expect(throws: BudgetStoreError.ruleNeedsAction) {
            try BudgetStore.validate(rule(
                conditions: [.init(op: "is", field: "payee", value: .string("p"), options: nil)],
                actions: []))
        }
    }

    /// `notes` disallows oneOf/notOneOf upstream (FIELD_INFO.disallowedOps).
    @Test func rejectsOperatorTheFieldDoesNotSupport() {
        #expect(throws: BudgetStoreError.ruleInvalidCondition(field: "notes", op: "oneOf")) {
            try BudgetStore.validate(rule(conditions: [
                .init(op: "oneOf", field: "notes", value: .list([.string("a")]), options: nil)
            ]))
        }
    }

    @Test func rejectsEmptyMultiValue() {
        #expect(throws: BudgetStoreError.ruleEmptyValue(field: "payee")) {
            try BudgetStore.validate(rule(conditions: [
                .init(op: "oneOf", field: "payee", value: .list([]), options: nil)
            ]))
        }
    }

    @Test func rejectsEmptyContainsValue() {
        #expect(throws: BudgetStoreError.ruleEmptyValue(field: "imported_payee")) {
            try BudgetStore.validate(rule(conditions: [
                .init(op: "contains", field: "imported_payee", value: .string(""), options: nil)
            ]))
        }
    }

    /// A date condition saved with no date would sync to every client and
    /// silently never match.
    @Test func rejectsIncompleteDateValue() {
        for value in ["", "2026", "2026-05"] {
            #expect(throws: BudgetStoreError.ruleEmptyValue(field: "date")) {
                try BudgetStore.validate(rule(conditions: [
                    .init(op: "gt", field: "date", value: .string(value), options: nil)
                ]))
            }
        }
    }

    @Test func acceptsFullDateValue() throws {
        try BudgetStore.validate(rule(conditions: [
            .init(op: "is", field: "date", value: .string("2026-05-03"), options: nil)
        ]))
    }

    @Test func rejectsUncompilableRegex() {
        #expect(throws: BudgetStoreError.ruleInvalidPattern(pattern: "[")) {
            try BudgetStore.validate(rule(conditions: [
                .init(op: "matches", field: "notes", value: .string("["), options: nil)
            ]))
        }
    }

    @Test func rejectsSetAccountToNothing() {
        #expect(throws: BudgetStoreError.ruleEmptyValue(field: "account")) {
            try BudgetStore.validate(rule(
                conditions: [.init(op: "is", field: "payee", value: .string("p"), options: nil)],
                actions: [.init(op: "set", field: "account", value: .null, options: nil)]))
        }
    }
}
