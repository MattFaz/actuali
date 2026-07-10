import Foundation
import Testing
@testable import Actuali

@MainActor
struct ConditionsFilterTests {

    private func makeTransaction(
        category: String? = nil,
        account: String = "acc1",
        amount: Int = -1000,
        payee: String? = nil
    ) -> Transaction {
        Transaction(
            id: UUID().uuidString,
            accountId: account,
            date: 20260301,
            amount: amount,
            payeeId: payee,
            payeeName: nil,
            categoryId: category,
            categoryName: nil,
            notes: nil,
            cleared: false,
            reconciled: false,
            transferId: nil,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: nil,
            importedPayee: nil
        )
    }

    @Test func passesWithNoConditions() {
        let tx = makeTransaction()
        #expect(ConditionsFilter.matches(transaction: tx, conditions: [], op: "and"))
    }

    @Test func passesWithNilConditions() {
        let tx = makeTransaction()
        #expect(ConditionsFilter.matches(transaction: tx, conditions: nil, op: "and"))
    }

    @Test func categoryIsMatch() {
        let tx = makeTransaction(category: "groceries")
        let cond = WidgetRuleCondition.makeMock(op: "is", field: "category", stringValue: "groceries")
        #expect(ConditionsFilter.matches(transaction: tx, conditions: [cond], op: "and"))
    }

    @Test func categoryIsMismatch() {
        let tx = makeTransaction(category: "rent")
        let cond = WidgetRuleCondition.makeMock(op: "is", field: "category", stringValue: "groceries")
        #expect(!ConditionsFilter.matches(transaction: tx, conditions: [cond], op: "and"))
    }

    @Test func accountIsMatch() {
        let tx = makeTransaction(account: "checking")
        let cond = WidgetRuleCondition.makeMock(op: "is", field: "account", stringValue: "checking")
        #expect(ConditionsFilter.matches(transaction: tx, conditions: [cond], op: "and"))
    }

    @Test func amountGreaterThan() {
        let tx = makeTransaction(amount: -2000)
        let cond = WidgetRuleCondition.makeMock(op: "gt", field: "amount", intValue: -3000)
        // tx.amount (-2000) > -3000 → true
        #expect(ConditionsFilter.matches(transaction: tx, conditions: [cond], op: "and"))
    }

    @Test func isNotInverts() {
        let tx = makeTransaction(category: "groceries")
        let cond = WidgetRuleCondition.makeMock(op: "isNot", field: "category", stringValue: "rent")
        #expect(ConditionsFilter.matches(transaction: tx, conditions: [cond], op: "and"))
    }

    @Test func andRequiresAllMatch() {
        let tx = makeTransaction(category: "groceries", account: "checking")
        let conds = [
            WidgetRuleCondition.makeMock(op: "is", field: "category", stringValue: "groceries"),
            WidgetRuleCondition.makeMock(op: "is", field: "account", stringValue: "savings")
        ]
        #expect(!ConditionsFilter.matches(transaction: tx, conditions: conds, op: "and"))
    }

    @Test func orRequiresOneMatch() {
        let tx = makeTransaction(category: "groceries", account: "checking")
        let conds = [
            WidgetRuleCondition.makeMock(op: "is", field: "category", stringValue: "rent"),
            WidgetRuleCondition.makeMock(op: "is", field: "account", stringValue: "checking")
        ]
        #expect(ConditionsFilter.matches(transaction: tx, conditions: conds, op: "or"))
    }

    @Test func unknownOpPassesThrough() {
        // Unknown ops default to true so widgets don't silently filter
        // everything out. Better to show too many transactions than zero.
        let tx = makeTransaction(category: "groceries")
        let cond = WidgetRuleCondition.makeMock(op: "weirdOp", field: "category", stringValue: "groceries")
        #expect(ConditionsFilter.matches(transaction: tx, conditions: [cond], op: "and"))
    }

    @Test func oneOfMatchesAnyValue() {
        let tx = makeTransaction(category: "groceries")
        let cond = WidgetRuleCondition.makeMock(
            op: "oneOf", field: "category",
            stringArrayValue: ["rent", "groceries", "fuel"]
        )
        #expect(ConditionsFilter.matches(transaction: tx, conditions: [cond], op: "and"))
    }

    @Test func oneOfMissesWhenNotInList() {
        let tx = makeTransaction(category: "entertainment")
        let cond = WidgetRuleCondition.makeMock(
            op: "oneOf", field: "category",
            stringArrayValue: ["rent", "groceries", "fuel"]
        )
        #expect(!ConditionsFilter.matches(transaction: tx, conditions: [cond], op: "and"))
    }

    @Test func notOneOfInverts() {
        // Common pattern: "exclude income categories" -> notOneOf(category, [income_ids])
        let tx = makeTransaction(category: "groceries")
        let cond = WidgetRuleCondition.makeMock(
            op: "notOneOf", field: "category",
            stringArrayValue: ["income-salary", "income-bonus"]
        )
        #expect(ConditionsFilter.matches(transaction: tx, conditions: [cond], op: "and"))
    }

    @Test func notOneOfRejectsListedValue() {
        let tx = makeTransaction(category: "income-salary")
        let cond = WidgetRuleCondition.makeMock(
            op: "notOneOf", field: "category",
            stringArrayValue: ["income-salary", "income-bonus"]
        )
        #expect(!ConditionsFilter.matches(transaction: tx, conditions: [cond], op: "and"))
    }

    @Test func containsIsCaseInsensitive() {
        let tx = Transaction(
            id: "1", accountId: "a", date: 20260301, amount: -100,
            payeeId: nil, payeeName: nil, categoryId: nil, categoryName: nil,
            notes: "Coffee at Bluebird Cafe", cleared: false, reconciled: false,
            transferId: nil, isParent: false, parentId: nil,
            tombstone: false, sortOrder: nil, importedPayee: nil
        )
        let cond = WidgetRuleCondition.makeMock(op: "contains", field: "notes", stringValue: "bluebird")
        #expect(ConditionsFilter.matches(transaction: tx, conditions: [cond], op: "and"))
    }

    // MARK: - Upstream parity added for issue #15

    private func decode(_ json: String) -> WidgetRuleCondition {
        try! JSONDecoder().decode(WidgetRuleCondition.self, from: Data(json.utf8))
    }

    @Test func onBudgetOpExcludesOffBudgetAccounts() {
        let context = ConditionsFilter.Context(offBudgetAccountIds: ["invest"], accountNames: [:])
        let cond = decode(#"{"op":"onBudget","field":"account","value":null}"#)
        #expect(ConditionsFilter.matches(transaction: makeTransaction(account: "checking"),
                                         conditions: [cond], op: "and", context: context))
        #expect(!ConditionsFilter.matches(transaction: makeTransaction(account: "invest"),
                                          conditions: [cond], op: "and", context: context))
    }

    @Test func offBudgetOpMatchesOnlyOffBudgetAccounts() {
        let context = ConditionsFilter.Context(offBudgetAccountIds: ["invest"], accountNames: [:])
        let cond = decode(#"{"op":"offBudget","field":"account","value":null}"#)
        #expect(ConditionsFilter.matches(transaction: makeTransaction(account: "invest"),
                                         conditions: [cond], op: "and", context: context))
        #expect(!ConditionsFilter.matches(transaction: makeTransaction(account: "checking"),
                                          conditions: [cond], op: "and", context: context))
    }

    @Test func outflowOptionGatesSignAndNegates() {
        // "outflow greater than 5.00" => amount < 0 and -amount > 500
        let cond = decode(#"{"op":"gt","field":"amount","value":500,"options":{"outflow":true}}"#)
        #expect(ConditionsFilter.matches(transaction: makeTransaction(amount: -600), conditions: [cond], op: "and"))
        #expect(!ConditionsFilter.matches(transaction: makeTransaction(amount: -400), conditions: [cond], op: "and"))
        #expect(!ConditionsFilter.matches(transaction: makeTransaction(amount: 700), conditions: [cond], op: "and"))
    }

    @Test func inflowOptionGatesSign() {
        let cond = decode(#"{"op":"gt","field":"amount","value":500,"options":{"inflow":true}}"#)
        #expect(ConditionsFilter.matches(transaction: makeTransaction(amount: 600), conditions: [cond], op: "and"))
        #expect(!ConditionsFilter.matches(transaction: makeTransaction(amount: -600), conditions: [cond], op: "and"))
    }

    @Test func legacyAmountInflowFieldName() {
        let cond = decode(#"{"op":"gt","field":"amount-inflow","value":500}"#)
        #expect(ConditionsFilter.matches(transaction: makeTransaction(amount: 600), conditions: [cond], op: "and"))
        #expect(!ConditionsFilter.matches(transaction: makeTransaction(amount: -600), conditions: [cond], op: "and"))
    }

    @Test func isBetweenComparesRawAmount() {
        let cond = decode(#"{"op":"isbetween","field":"amount","value":{"num1":-2000,"num2":-500}}"#)
        #expect(ConditionsFilter.matches(transaction: makeTransaction(amount: -1000), conditions: [cond], op: "and"))
        #expect(!ConditionsFilter.matches(transaction: makeTransaction(amount: -3000), conditions: [cond], op: "and"))
    }

    @Test func dateIsMonthMatchesWholeMonth() {
        // Transaction date is 20260301.
        let cond = decode(#"{"op":"is","field":"date","value":"2026-03"}"#)
        #expect(ConditionsFilter.matches(transaction: makeTransaction(), conditions: [cond], op: "and"))
        let other = decode(#"{"op":"is","field":"date","value":"2026-04"}"#)
        #expect(!ConditionsFilter.matches(transaction: makeTransaction(), conditions: [other], op: "and"))
    }

    @Test func dateComparisonOps() {
        let cond = decode(#"{"op":"gte","field":"date","value":"2026-03-01"}"#)
        #expect(ConditionsFilter.matches(transaction: makeTransaction(), conditions: [cond], op: "and"))
        let later = decode(#"{"op":"gt","field":"date","value":"2026-03-01"}"#)
        #expect(!ConditionsFilter.matches(transaction: makeTransaction(), conditions: [later], op: "and"))
    }

    @Test func categoryIsNothingMatchesUncategorizedButNotTransfers() {
        let cond = decode(#"{"op":"is","field":"category","value":null}"#)
        #expect(ConditionsFilter.matches(transaction: makeTransaction(category: nil), conditions: [cond], op: "and"))
        #expect(!ConditionsFilter.matches(transaction: makeTransaction(category: "groceries"), conditions: [cond], op: "and"))

        // Transfer legs are uncategorized but must not match (upstream
        // conditionSpecialCases adds transfer=false).
        var transfer = makeTransaction(category: nil)
        transfer.transferId = "other-leg"
        #expect(!ConditionsFilter.matches(transaction: transfer, conditions: [cond], op: "and"))
    }

    @Test func idContainsMatchesReferencedName() {
        var tx = makeTransaction(payee: "payee-uuid")
        tx.payeeName = "Woolworths Metro"
        let cond = WidgetRuleCondition.makeMock(op: "contains", field: "payee", stringValue: "woolworths")
        #expect(ConditionsFilter.matches(transaction: tx, conditions: [cond], op: "and"))
        let miss = WidgetRuleCondition.makeMock(op: "contains", field: "payee", stringValue: "coles")
        #expect(!ConditionsFilter.matches(transaction: tx, conditions: [miss], op: "and"))
    }

    @Test func matchesOpUsesRegex() {
        var tx = makeTransaction(payee: "payee-uuid")
        tx.payeeName = "Uber Eats 123"
        let cond = WidgetRuleCondition.makeMock(op: "matches", field: "payee", stringValue: "^uber")
        #expect(ConditionsFilter.matches(transaction: tx, conditions: [cond], op: "and"))
    }

    @Test func customNameConditionsAreSkipped() {
        // Saved-filter references (customName) are dropped upstream before
        // filtering; an otherwise-impossible condition must not exclude rows.
        let cond = decode(#"{"op":"is","field":"category","value":"nope","customName":"My saved filter"}"#)
        #expect(ConditionsFilter.matches(transaction: makeTransaction(category: "groceries"),
                                         conditions: [cond], op: "and"))
    }

    @Test func oneOfEmptyArrayMatchesNothing() {
        let cond = WidgetRuleCondition.makeMock(op: "oneOf", field: "category", stringArrayValue: [])
        #expect(!ConditionsFilter.matches(transaction: makeTransaction(category: "groceries"),
                                          conditions: [cond], op: "and"))
    }

    @Test func hasTagsMatchesTagBoundaries() {
        var tx = makeTransaction()
        tx.notes = "dinner #eating-out with friends"
        let cond = WidgetRuleCondition.makeMock(op: "hasTags", field: "notes", stringValue: "#eating-out")
        #expect(ConditionsFilter.matches(transaction: tx, conditions: [cond], op: "and"))
        let miss = WidgetRuleCondition.makeMock(op: "hasTags", field: "notes", stringValue: "#travel")
        #expect(!ConditionsFilter.matches(transaction: tx, conditions: [miss], op: "and"))
    }
}

/// Test helper to build WidgetRuleCondition values from primitives.
extension WidgetRuleCondition {
    static func makeMock(
        op: String,
        field: String,
        stringValue: String? = nil,
        intValue: Int? = nil,
        stringArrayValue: [String]? = nil
    ) -> WidgetRuleCondition {
        let json: String
        if let arr = stringArrayValue {
            let arrJSON = "[" + arr.map { "\"\($0)\"" }.joined(separator: ",") + "]"
            json = #"{"op":"\#(op)","field":"\#(field)","value":\#(arrJSON)}"#
        } else if let s = stringValue {
            json = #"{"op":"\#(op)","field":"\#(field)","value":"\#(s)"}"#
        } else if let i = intValue {
            json = #"{"op":"\#(op)","field":"\#(field)","value":\#(i)}"#
        } else {
            json = #"{"op":"\#(op)","field":"\#(field)","value":null}"#
        }
        return try! JSONDecoder().decode(WidgetRuleCondition.self, from: Data(json.utf8))
    }
}
