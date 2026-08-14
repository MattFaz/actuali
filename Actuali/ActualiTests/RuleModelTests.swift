import Testing
@testable import Actuali

/// Round-tripping rules through the JSON blobs Actual stores them in. Field
/// names must come back out internal (`description`, `acct`) or the web app and
/// the sync engine will read a rule we wrote as a different rule.
struct RuleModelTests {

    @Test func parsesInternalFieldNamesToPublicOnes() throws {
        let rule = try Rule.parse(
            id: "r-1", stage: "pre", conditionsOp: "or",
            conditionsJSON: #"[{"op":"is","field":"description","value":"payee-1","type":"id"}]"#,
            actionsJSON: #"[{"op":"set","field":"acct","value":"acct-1","type":"id"}]"#
        )

        #expect(rule.stage == .pre)
        #expect(rule.conditionsOp == .or)
        #expect(rule.conditions[0].field == "payee")
        #expect(rule.conditions[0].value == .string("payee-1"))
        #expect(rule.actions[0].field == "account")
    }

    @Test func serializesBackToInternalFieldNames() throws {
        let rule = Rule(
            id: "r-1", stage: .default, conditionsOp: .and,
            conditions: [.init(op: "contains", field: "imported_payee",
                               value: .string("woolworths"), options: nil)],
            actions: [.init(op: "set", field: "payee", value: .string("payee-1"), options: nil)]
        )

        #expect(rule.conditionsJSON.contains(#""field":"imported_description""#))
        #expect(rule.actionsJSON.contains(#""field":"description""#))
        #expect(rule.conditionsJSON.contains(#""type":"string""#))
    }

    @Test func roundTripsUnchanged() throws {
        let conditions = #"[{"field":"amount","op":"isbetween","type":"number","value":{"num1":-5000,"num2":-1000}}]"#
        let actions = #"[{"field":"category","op":"set","type":"id","value":"cat-1"}]"#
        let rule = try Rule.parse(id: "r-1", stage: nil, conditionsOp: "and",
                                  conditionsJSON: conditions, actionsJSON: actions)

        #expect(rule.conditionsJSON == conditions)
        #expect(rule.actionsJSON == actions)
    }

    @Test func amountsSerializeAsIntegerCents() {
        #expect(RuleValue.number(1050).jsonObject as? Int == 1050)
    }

    @Test func defaultStageWritesNullStage() {
        let rule = Rule.empty(id: "r-1")
        #expect(rule.syncableFields["stage"] as? String == nil)
        #expect(rule.syncableFields["conditions_op"] as? String == "and")
    }
}
