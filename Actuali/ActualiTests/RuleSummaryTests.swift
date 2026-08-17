import Testing
@testable import Actuali

/// The IF/THEN text on the rules list, and the string its search box matches.
struct RuleSummaryTests {

    private let summary = RuleSummary(
        names: .init(
            payees: ["payee-1": "Woolworths"],
            categories: ["cat-1": "Groceries"],
            categoryGroups: ["grp-1": "Daily"],
            accounts: ["acct-1": "Checking"]
        ),
        formatAmount: { cents in "$\(Double(cents) / 100)" }
    )

    @Test func namesIdsInsteadOfShowingUUIDs() {
        let condition = Rule.Condition(op: "is", field: "payee",
                                       value: .string("payee-1"), options: nil)
        #expect(summary.condition(condition) == "payee is Woolworths")
    }

    @Test func labelsAmountDirectionFromOptions() {
        let condition = Rule.Condition(op: "gt", field: "amount", value: .number(5000),
                                       options: ["outflow": .bool(true)])
        #expect(summary.condition(condition).hasPrefix("amount (outflow) is greater than"))
    }

    @Test func rendersOpsWithoutAValue() {
        let condition = Rule.Condition(op: "offBudget", field: "account",
                                       value: .null, options: nil)
        #expect(summary.condition(condition) == "account is off budget")
    }

    @Test func describesActions() {
        let action = Rule.Action(op: "set", field: "category",
                                 value: .string("cat-1"), options: nil)
        #expect(summary.action(action) == "set category to Groceries")
    }

    @Test func searchTextCoversConditionsAndActions() {
        let rule = Rule(
            id: "r-1", stage: .default, conditionsOp: .and,
            conditions: [.init(op: "contains", field: "imported_payee",
                               value: .string("WOOLIES"), options: nil)],
            actions: [.init(op: "set", field: "category", value: .string("cat-1"), options: nil)])

        let text = summary.searchText(rule)
        #expect(text.contains("woolies"))
        #expect(text.contains("groceries"))
    }
}
