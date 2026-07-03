import Testing
@testable import Actuali

struct RulesEngineTests {

    // MARK: - Helpers

    private func makeTransaction(
        importedPayee: String? = nil,
        payeeId: String? = nil,
        amount: Int = -500,
        notes: String? = nil
    ) -> Transaction {
        Transaction(
            id: "tx-1",
            accountId: "acct-1",
            date: 20260503,
            amount: amount,
            payeeId: payeeId,
            payeeName: nil,
            categoryId: nil,
            categoryName: nil,
            notes: notes,
            cleared: false,
            reconciled: false,
            transferId: nil,
            isParent: false,
            parentId: nil,
            tombstone: false,
            sortOrder: nil,
            importedPayee: importedPayee
        )
    }

    private func parseRule(
        id: String = "r-1",
        stage: String? = nil,
        op: String? = "and",
        conditions: String,
        actions: String
    ) -> Rule {
        try! Rule.parse(
            id: id,
            stage: stage,
            conditionsOp: op,
            conditionsJSON: conditions,
            actionsJSON: actions
        )
    }

    // MARK: - The user's actual scenario

    @Test func importedPayeeContainsTriggersRenameRule() {
        // Stored exactly as Actual writes them: internal field name
        // `imported_description`, `description` (which translate to
        // `imported_payee` and `payee` for evaluation).
        let rule = parseRule(
            conditions: """
            [{"op":"contains","field":"imported_description","value":"woolworths"}]
            """,
            actions: """
            [{"op":"set","field":"description","value":"payee-woolworths-id"}]
            """
        )

        let tx = makeTransaction(importedPayee: "Woolworths 3029", payeeId: "payee-other-id")
        let (updated, changed) = RulesEngine.apply(tx, rules: [rule])

        #expect(updated.payeeId == "payee-woolworths-id")
        #expect(changed.contains("payee"))
    }

    @Test func ruleDoesNotFireWhenImportedPayeeMissing() {
        let rule = parseRule(
            conditions: """
            [{"op":"contains","field":"imported_description","value":"woolworths"}]
            """,
            actions: """
            [{"op":"set","field":"description","value":"payee-woolworths-id"}]
            """
        )

        let tx = makeTransaction(importedPayee: nil, payeeId: "payee-other-id")
        let (updated, changed) = RulesEngine.apply(tx, rules: [rule])

        #expect(updated.payeeId == "payee-other-id")
        #expect(changed.isEmpty)
    }

    @Test func containsIsCaseInsensitive() {
        let rule = parseRule(
            conditions: """
            [{"op":"contains","field":"imported_description","value":"WOOLWORTHS"}]
            """,
            actions: """
            [{"op":"set","field":"description","value":"payee-w"}]
            """
        )
        let tx = makeTransaction(importedPayee: "woolworths #4")
        let (updated, _) = RulesEngine.apply(tx, rules: [rule])
        #expect(updated.payeeId == "payee-w")
    }

    // MARK: - Condition ops

    @Test func isOpMatchesPayeeId() {
        let rule = parseRule(
            conditions: """
            [{"op":"is","field":"description","value":"payee-coffee"}]
            """,
            actions: """
            [{"op":"set","field":"category","value":"cat-food"}]
            """
        )
        let tx = makeTransaction(payeeId: "payee-coffee")
        let (updated, _) = RulesEngine.apply(tx, rules: [rule])
        #expect(updated.categoryId == "cat-food")
    }

    @Test func oneOfMatchesAnyValue() {
        let rule = parseRule(
            conditions: """
            [{"op":"oneOf","field":"description","value":["payee-a","payee-b"]}]
            """,
            actions: """
            [{"op":"set","field":"category","value":"cat-x"}]
            """
        )
        let tx = makeTransaction(payeeId: "payee-b")
        let (updated, _) = RulesEngine.apply(tx, rules: [rule])
        #expect(updated.categoryId == "cat-x")
    }

    @Test func gtComparesAmount() {
        let rule = parseRule(
            conditions: """
            [{"op":"gt","field":"amount","value":1000}]
            """,
            actions: """
            [{"op":"set","field":"category","value":"cat-big"}]
            """
        )
        let tx = makeTransaction(amount: 1500)
        let (updated, _) = RulesEngine.apply(tx, rules: [rule])
        #expect(updated.categoryId == "cat-big")
    }

    @Test func outflowOptionInvertsAmountSign() {
        // outflow: only matches when amount < 0; absolute value compared
        let rule = parseRule(
            conditions: """
            [{"op":"gt","field":"amount","value":1000,"options":{"outflow":true}}]
            """,
            actions: """
            [{"op":"set","field":"category","value":"cat-big-spend"}]
            """
        )
        let outflowTx = makeTransaction(amount: -1500)
        let (updated, _) = RulesEngine.apply(outflowTx, rules: [rule])
        #expect(updated.categoryId == "cat-big-spend")

        let inflowTx = makeTransaction(amount: 1500)
        let (notUpdated, _) = RulesEngine.apply(inflowTx, rules: [rule])
        #expect(notUpdated.categoryId == nil)
    }

    @Test func matchesUsesRegex() {
        let rule = parseRule(
            conditions: """
            [{"op":"matches","field":"imported_description","value":"^STARBUCKS"}]
            """,
            actions: """
            [{"op":"set","field":"category","value":"cat-coffee"}]
            """
        )
        let tx = makeTransaction(importedPayee: "Starbucks #1234")
        let (updated, _) = RulesEngine.apply(tx, rules: [rule])
        #expect(updated.categoryId == "cat-coffee")
    }

    @Test func conditionsOpOrMatchesEither() {
        let rule = parseRule(
            op: "or",
            conditions: """
            [
              {"op":"contains","field":"imported_description","value":"coffee"},
              {"op":"contains","field":"imported_description","value":"cafe"}
            ]
            """,
            actions: """
            [{"op":"set","field":"category","value":"cat-coffee"}]
            """
        )
        let tx = makeTransaction(importedPayee: "Local Cafe")
        let (updated, _) = RulesEngine.apply(tx, rules: [rule])
        #expect(updated.categoryId == "cat-coffee")
    }

    // MARK: - Actions

    @Test func appendNotesAppends() {
        let rule = parseRule(
            conditions: """
            [{"op":"contains","field":"imported_description","value":"X"}]
            """,
            actions: """
            [{"op":"append-notes","value":" [auto]"}]
            """
        )
        let tx = makeTransaction(importedPayee: "X-Co", notes: "lunch")
        let (updated, _) = RulesEngine.apply(tx, rules: [rule])
        #expect(updated.notes == "lunch [auto]")
    }

    @Test func prependNotesPrepends() {
        let rule = parseRule(
            conditions: """
            [{"op":"contains","field":"imported_description","value":"X"}]
            """,
            actions: """
            [{"op":"prepend-notes","value":"[auto] "}]
            """
        )
        let tx = makeTransaction(importedPayee: "X-Co", notes: "lunch")
        let (updated, _) = RulesEngine.apply(tx, rules: [rule])
        #expect(updated.notes == "[auto] lunch")
    }

    @Test func appendNotesOnNilStartsFresh() {
        let rule = parseRule(
            conditions: """
            [{"op":"contains","field":"imported_description","value":"X"}]
            """,
            actions: """
            [{"op":"append-notes","value":"auto"}]
            """
        )
        let tx = makeTransaction(importedPayee: "X-Co", notes: nil)
        let (updated, _) = RulesEngine.apply(tx, rules: [rule])
        #expect(updated.notes == "auto")
    }

    // MARK: - Amount conversion guards

    @Test func setAmountFractionalDoubleRoundsToNearestCent() {
        let rule = parseRule(
            conditions: """
            [{"op":"contains","field":"imported_description","value":"X"}]
            """,
            actions: """
            [{"op":"set","field":"amount","value":819.99}]
            """
        )
        let tx = makeTransaction(importedPayee: "X-Co", amount: -500)
        let (updated, changed) = RulesEngine.apply(tx, rules: [rule])
        #expect(updated.amount == 820)
        #expect(changed.contains("amount"))
    }

    @Test func setAmountNonFiniteLeavesAmountUnchanged() {
        for bad in [Double.infinity, -Double.infinity, Double.nan, 1e30] {
            let rule = Rule(
                id: "bad-amount",
                stage: .default,
                conditionsOp: .and,
                conditions: [
                    Rule.Condition(op: "contains", field: "imported_payee", value: "X", options: nil)
                ],
                actions: [
                    Rule.Action(op: "set", field: "amount", value: bad, options: nil)
                ]
            )
            let tx = makeTransaction(importedPayee: "X-Co", amount: -500)
            // Must not trap; garbage values are dropped and the original
            // amount is preserved.
            let (updated, _) = RulesEngine.apply(tx, rules: [rule])
            #expect(updated.amount == -500)
        }
    }

    // MARK: - Stage ordering

    @Test func preStageRunsBeforeDefault() {
        // pre rule sets imported_payee → payee mapping
        let pre = parseRule(
            id: "pre-1",
            stage: "pre",
            conditions: """
            [{"op":"contains","field":"imported_description","value":"woolworths"}]
            """,
            actions: """
            [{"op":"set","field":"description","value":"payee-w"}]
            """
        )
        // default rule keys off the rewritten payee
        let def = parseRule(
            id: "def-1",
            stage: nil,
            conditions: """
            [{"op":"is","field":"description","value":"payee-w"}]
            """,
            actions: """
            [{"op":"set","field":"category","value":"cat-groceries"}]
            """
        )

        let tx = makeTransaction(importedPayee: "Woolworths 3029")
        // Pass in default-then-pre order; engine must run pre first.
        let (updated, _) = RulesEngine.apply(tx, rules: [def, pre])
        #expect(updated.payeeId == "payee-w")
        #expect(updated.categoryId == "cat-groceries")
    }

    // MARK: - Unsupported ops

    @Test func unsupportedActionDoesNotChangeFields() {
        let rule = parseRule(
            conditions: """
            [{"op":"contains","field":"imported_description","value":"X"}]
            """,
            actions: """
            [{"op":"link-schedule","value":"sched-1"}]
            """
        )
        let tx = makeTransaction(importedPayee: "X-Co", payeeId: "payee-original")
        let (updated, changed) = RulesEngine.apply(tx, rules: [rule])
        #expect(updated.payeeId == "payee-original")
        #expect(changed.isEmpty)
    }

    @Test func malformedRuleJSONIsIgnored() {
        // RulesEngine should keep going if a rule has bad JSON — we test the
        // engine's resilience to empty conditions arrays here. (BudgetDatabase
        // filters out parse errors before they reach the engine.)
        let rule = Rule(
            id: "bad",
            stage: .default,
            conditionsOp: .and,
            conditions: [],
            actions: []
        )
        let tx = makeTransaction(importedPayee: "X")
        let (updated, changed) = RulesEngine.apply(tx, rules: [rule])
        #expect(updated.importedPayee == "X")
        #expect(changed.isEmpty)
    }

    // MARK: - hasTags / hasAnyTag (upstream 26.7.0 semantics)

    private func tagRule(op: String, value: String) -> Rule {
        parseRule(
            conditions: """
            [{"op":"\(op)","field":"notes","value":"\(value)"}]
            """,
            actions: """
            [{"op":"set","field":"category","value":"cat-tagged"}]
            """
        )
    }

    @Test func hasTagsMatchesAllTagsCaseInsensitively() {
        let rule = tagRule(op: "hasTags", value: "#work #urgent")
        let tx = makeTransaction(notes: "errand #Work also #URGENT")
        let (updated, _) = RulesEngine.apply(tx, rules: [rule])
        #expect(updated.categoryId == "cat-tagged")
    }

    @Test func hasTagsDoesNotFireWhenATagIsMissing() {
        let rule = tagRule(op: "hasTags", value: "#work #urgent")
        let tx = makeTransaction(notes: "#work only")
        let (updated, _) = RulesEngine.apply(tx, rules: [rule])
        #expect(updated.categoryId == nil)
    }

    @Test func hasAnyTagFiresOnAnySingleMatch() {
        let rule = tagRule(op: "hasAnyTag", value: "#work #urgent")
        let tx = makeTransaction(notes: "#urgent errand")
        let (updated, _) = RulesEngine.apply(tx, rules: [rule])
        #expect(updated.categoryId == "cat-tagged")
    }

    @Test func tagMatchingSkipsHiddenAndPartialTags() {
        // ##work is a hidden tag ((?<!#) lookbehind) and #workout must not
        // count as a word-boundary match for #work.
        let rule = tagRule(op: "hasAnyTag", value: "#work")
        let tx = makeTransaction(notes: "##work #workout")
        let (updated, _) = RulesEngine.apply(tx, rules: [rule])
        #expect(updated.categoryId == nil)
    }

    @Test func hasAnyTagDoesNotFireWithoutNotes() {
        let rule = tagRule(op: "hasAnyTag", value: "#work")
        let tx = makeTransaction(notes: nil)
        let (updated, _) = RulesEngine.apply(tx, rules: [rule])
        #expect(updated.categoryId == nil)
    }
}
