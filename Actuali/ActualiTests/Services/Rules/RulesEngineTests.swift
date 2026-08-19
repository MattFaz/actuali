import Testing
@testable import Actuali

/// Rule evaluation against a single transaction — the port of loot-core's
/// `runRules` (server/transactions/transaction-rules.ts) plus the condition and
/// action semantics of `server/rules/{condition,action}.ts`.
///
/// Rules are written here as the JSON blobs Actual actually stores, internal
/// column names and all (`description` for payee, `imported_description` for
/// imported payee, `acct` for account), so a test that passes is evidence the
/// engine reads what the web app writes.
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

    /// The pair most of these tests care about. `RulesEngine.apply` returns the
    /// full `RuleRunResult`; the delete and payee-name channels are asserted
    /// against the result directly in the tests that exercise them.
    private func applied(
        _ transaction: Transaction,
        rules: [Rule],
        context: RuleContext = .empty
    ) -> (Transaction, Set<String>) {
        let result = RulesEngine.apply(transaction, rules: rules, context: context)
        return (result.transaction, result.changedFields)
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
        let (updated, changed) = applied(tx, rules: [rule])

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
        let (updated, changed) = applied(tx, rules: [rule])

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
        let (updated, _) = applied(tx, rules: [rule])
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
        let (updated, _) = applied(tx, rules: [rule])
        #expect(updated.categoryId == "cat-food")
    }

    @Test func isNotOpMatchesEverythingElse() {
        let rule = parseRule(
            conditions: """
            [{"op":"isNot","field":"description","value":"payee-coffee"}]
            """,
            actions: """
            [{"op":"set","field":"category","value":"cat-other"}]
            """
        )
        #expect(applied(makeTransaction(payeeId: "payee-tea"), rules: [rule]).0.categoryId == "cat-other")
        #expect(applied(makeTransaction(payeeId: "payee-coffee"), rules: [rule]).0.categoryId == nil)
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
        let (updated, _) = applied(tx, rules: [rule])
        #expect(updated.categoryId == "cat-x")
    }

    @Test func notOneOfExcludesListedValues() {
        let rule = parseRule(
            conditions: """
            [{"op":"notOneOf","field":"description","value":["payee-a","payee-b"]}]
            """,
            actions: """
            [{"op":"set","field":"category","value":"cat-rest"}]
            """
        )
        #expect(applied(makeTransaction(payeeId: "payee-c"), rules: [rule]).0.categoryId == "cat-rest")
        #expect(applied(makeTransaction(payeeId: "payee-a"), rules: [rule]).0.categoryId == nil)
        // Upstream returns false for a null field value on notOneOf too.
        #expect(applied(makeTransaction(payeeId: nil), rules: [rule]).0.categoryId == nil)
    }

    @Test func doesNotContainExcludesMatchingText() {
        let rule = parseRule(
            conditions: """
            [{"op":"doesNotContain","field":"imported_description","value":"refund"}]
            """,
            actions: """
            [{"op":"set","field":"category","value":"cat-spend"}]
            """
        )
        #expect(applied(makeTransaction(importedPayee: "Shop Co"), rules: [rule]).0.categoryId == "cat-spend")
        #expect(applied(makeTransaction(importedPayee: "Shop Co REFUND"), rules: [rule]).0.categoryId == nil)
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
        let (updated, _) = applied(tx, rules: [rule])
        #expect(updated.categoryId == "cat-big")
    }

    @Test func isBetweenMatchesInclusiveRange() {
        let rule = parseRule(
            conditions: """
            [{"op":"isbetween","field":"amount","value":{"num1":-2000,"num2":-1000}}]
            """,
            actions: """
            [{"op":"set","field":"category","value":"cat-mid"}]
            """
        )
        #expect(applied(makeTransaction(amount: -1500), rules: [rule]).0.categoryId == "cat-mid")
        // Bounds are inclusive, and the stored order of num1/num2 doesn't matter.
        #expect(applied(makeTransaction(amount: -1000), rules: [rule]).0.categoryId == "cat-mid")
        #expect(applied(makeTransaction(amount: -2000), rules: [rule]).0.categoryId == "cat-mid")
        #expect(applied(makeTransaction(amount: -500), rules: [rule]).0.categoryId == nil)
    }

    /// `getApproxNumberThreshold` rounds (1000 × 0.075 = 75). Flooring instead
    /// made amounts inside the web app's window miss the rule here.
    @Test func approxAmountUsesRoundedThreshold() {
        let rule = parseRule(
            conditions: #"[{"op":"isapprox","field":"amount","value":-1000}]"#,
            actions: #"[{"op":"set","field":"category","value":"cat-approx"}]"#)

        #expect(applied(makeTransaction(amount: -1075), rules: [rule]).0.categoryId == "cat-approx")
        #expect(applied(makeTransaction(amount: -1076), rules: [rule]).0.categoryId == nil)
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
        let (updated, _) = applied(outflowTx, rules: [rule])
        #expect(updated.categoryId == "cat-big-spend")

        let inflowTx = makeTransaction(amount: 1500)
        let (notUpdated, _) = applied(inflowTx, rules: [rule])
        #expect(notUpdated.categoryId == nil)
    }

    @Test func inflowOptionRequiresPositiveAmount() {
        let rule = parseRule(
            conditions: """
            [{"op":"gt","field":"amount","value":1000,"options":{"inflow":true}}]
            """,
            actions: """
            [{"op":"set","field":"category","value":"cat-income"}]
            """
        )
        #expect(applied(makeTransaction(amount: 1500), rules: [rule]).0.categoryId == "cat-income")
        #expect(applied(makeTransaction(amount: -1500), rules: [rule]).0.categoryId == nil)
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
        let (updated, _) = applied(tx, rules: [rule])
        #expect(updated.categoryId == "cat-coffee")
    }

    /// Upstream lowercases the pattern itself at parse time, so `\D` runs as
    /// `\d`. A rule written on the web has to behave the same here, quirk
    /// included — see the comment in RulesEngine.evalText.
    @Test func matchesLowercasesThePatternLikeUpstream() {
        let rule = parseRule(
            conditions: #"[{"op":"matches","field":"notes","value":"\\D+"}]"#,
            actions: #"[{"op":"set","field":"category","value":"cat-digits"}]"#)
        // "1234" contains no non-digits, but \D lowercases to \d and matches.
        let tx = makeTransaction(notes: "1234")
        let (updated, _) = applied(tx, rules: [rule])
        #expect(updated.categoryId == "cat-digits")
    }

    @Test func invalidRegexNeverMatches() {
        let rule = parseRule(
            conditions: #"[{"op":"matches","field":"notes","value":"["}]"#,
            actions: #"[{"op":"set","field":"category","value":"cat-bad"}]"#)
        let (updated, _) = applied(makeTransaction(notes: "anything"), rules: [rule])
        #expect(updated.categoryId == nil)
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
        let (updated, _) = applied(tx, rules: [rule])
        #expect(updated.categoryId == "cat-coffee")
    }

    /// Upstream coerces a missing string field to "" before comparing
    /// (`fieldValue ??= ''`), so a note-less transaction matches `is ""`.
    @Test func emptyNotesMatchesIsEmptyString() {
        let rule = parseRule(
            conditions: #"[{"op":"is","field":"notes","value":"","type":"string"}]"#,
            actions: #"[{"op":"set","field":"category","value":"cat-empty"}]"#)
        let (updated, _) = applied(makeTransaction(notes: nil), rules: [rule])
        #expect(updated.categoryId == "cat-empty")
    }

    // MARK: - Date conditions

    @Test func exactDateConditionMatches() {
        let rule = parseRule(
            conditions: #"[{"op":"is","field":"date","value":"2026-05-03","type":"date"}]"#,
            actions: #"[{"op":"set","field":"category","value":"cat-day"}]"#)
        let (updated, _) = applied(makeTransaction(), rules: [rule])
        #expect(updated.categoryId == "cat-day")
    }

    @Test func monthDateConditionMatches() {
        let rule = parseRule(
            conditions: #"[{"op":"is","field":"date","value":"2026-05","type":"date"}]"#,
            actions: #"[{"op":"set","field":"category","value":"cat-month"}]"#)
        let (updated, _) = applied(makeTransaction(), rules: [rule])
        #expect(updated.categoryId == "cat-month")
    }

    @Test func yearDateConditionMatches() {
        let rule = parseRule(
            conditions: #"[{"op":"is","field":"date","value":"2026","type":"date"}]"#,
            actions: #"[{"op":"set","field":"category","value":"cat-year"}]"#)
        let (updated, _) = applied(makeTransaction(), rules: [rule])
        #expect(updated.categoryId == "cat-year")
    }

    /// Upstream widens an exact date by ±2 days.
    @Test func approxDateMatchesWithinTwoDays() {
        let rule = parseRule(
            conditions: #"[{"op":"isapprox","field":"date","value":"2026-05-05","type":"date"}]"#,
            actions: #"[{"op":"set","field":"category","value":"cat-near"}]"#)
        // The transaction is dated 20260503 — two days out, inclusive.
        let (updated, _) = applied(makeTransaction(), rules: [rule])
        #expect(updated.categoryId == "cat-near")
    }

    @Test func approxDateMissesOutsideTwoDays() {
        let rule = parseRule(
            conditions: #"[{"op":"isapprox","field":"date","value":"2026-05-07","type":"date"}]"#,
            actions: #"[{"op":"set","field":"category","value":"cat-far"}]"#)
        let (updated, _) = applied(makeTransaction(), rules: [rule])
        #expect(updated.categoryId == nil)
    }

    @Test func dateComparisonOps() {
        func category(forOp op: String, value: String) -> String? {
            let rule = parseRule(
                conditions: #"[{"op":"\#(op)","field":"date","value":"\#(value)","type":"date"}]"#,
                actions: #"[{"op":"set","field":"category","value":"cat-hit"}]"#)
            return applied(makeTransaction(), rules: [rule]).0.categoryId
        }

        // The transaction is dated 20260503.
        #expect(category(forOp: "gt", value: "2026-05-02") == "cat-hit")
        #expect(category(forOp: "gt", value: "2026-05-03") == nil)
        #expect(category(forOp: "gte", value: "2026-05-03") == "cat-hit")
        #expect(category(forOp: "lt", value: "2026-05-04") == "cat-hit")
        #expect(category(forOp: "lt", value: "2026-05-03") == nil)
        #expect(category(forOp: "lte", value: "2026-05-03") == "cat-hit")
    }

    /// A month or year value fails `Condition`'s parse assertions upstream, so
    /// the rule never loads there. Here the condition simply can't match.
    @Test func dateComparisonRejectsMonthPrecision() {
        let rule = parseRule(
            conditions: #"[{"op":"gt","field":"date","value":"2026-04","type":"date"}]"#,
            actions: #"[{"op":"set","field":"category","value":"cat-month"}]"#)
        let (updated, _) = applied(makeTransaction(), rules: [rule])
        #expect(updated.categoryId == nil)
    }

    // MARK: - Conditions that need budget context

    /// `category_group` is not a transaction column; it's resolved from the
    /// category through `RuleContext`, the way upstream's
    /// `prepareTransactionForRules` hangs it off the transaction.
    @Test func categoryGroupConditionUsesContext() {
        let rule = parseRule(
            conditions: #"[{"op":"is","field":"category_group","value":"grp-daily","type":"id"}]"#,
            actions: #"[{"op":"set","field":"notes","value":"daily"}]"#)
        var tx = makeTransaction()
        tx.categoryId = "cat-food"

        let context = RuleContext(categoryGroupIds: ["cat-food": "grp-daily"])
        #expect(applied(tx, rules: [rule], context: context).0.notes == "daily")
        // Without the context the group is unknown and the rule can't match.
        #expect(applied(tx, rules: [rule]).0.notes == nil)
    }

    @Test func payeeNameConditionUsesContext() {
        let rule = parseRule(
            conditions: #"[{"op":"contains","field":"payee_name","value":"wool","type":"string"}]"#,
            actions: #"[{"op":"set","field":"category","value":"cat-groceries"}]"#)
        let tx = makeTransaction(payeeId: "payee-1")

        let context = RuleContext(payeeNames: ["payee-1": "Woolworths"])
        #expect(applied(tx, rules: [rule], context: context).0.categoryId == "cat-groceries")
        #expect(applied(tx, rules: [rule]).0.categoryId == nil)
    }

    @Test func offBudgetConditionMatchesOffBudgetAccount() {
        let rule = parseRule(
            conditions: #"[{"op":"offBudget","field":"acct","value":null,"type":"id"}]"#,
            actions: #"[{"op":"set","field":"category","value":"cat-off"}]"#)
        let tx = makeTransaction()   // account is "acct-1"

        #expect(applied(tx, rules: [rule],
                        context: RuleContext(offBudgetAccountIds: ["acct-1"])).0.categoryId == "cat-off")
        #expect(applied(tx, rules: [rule],
                        context: RuleContext(offBudgetAccountIds: ["acct-other"])).0.categoryId == nil)
    }

    @Test func onBudgetConditionMatchesBudgetedAccount() {
        let rule = parseRule(
            conditions: #"[{"op":"onBudget","field":"acct","value":null,"type":"id"}]"#,
            actions: #"[{"op":"set","field":"category","value":"cat-on"}]"#)
        let tx = makeTransaction()

        #expect(applied(tx, rules: [rule],
                        context: RuleContext(offBudgetAccountIds: ["acct-other"])).0.categoryId == "cat-on")
        #expect(applied(tx, rules: [rule],
                        context: RuleContext(offBudgetAccountIds: ["acct-1"])).0.categoryId == nil)
    }

    /// Upstream's live `Condition.eval` can never match `transfer` or `parent`:
    /// the prepared transaction has no such keys, so it hits
    /// `fieldValue === undefined` and returns false. Only the query path
    /// (`conditionsToAQL`, mirrored by ConditionsFilter) maps them to columns.
    @Test func transferConditionsNeverMatchInTheEngine() {
        let rule = parseRule(
            conditions: #"[{"op":"is","field":"transfer","value":true,"type":"boolean"}]"#,
            actions: #"[{"op":"set","field":"category","value":"cat-transfer"}]"#)
        var tx = makeTransaction()
        tx.transferId = "tx-2"

        let (updated, _) = applied(tx, rules: [rule])
        #expect(updated.categoryId == nil)
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
        let (updated, _) = applied(tx, rules: [rule])
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
        let (updated, _) = applied(tx, rules: [rule])
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
        let (updated, _) = applied(tx, rules: [rule])
        #expect(updated.notes == "auto")
    }

    /// `set payee_name` parks the name for the caller to resolve to an id
    /// (creating the payee if it's new), matching upstream's
    /// `resolvePayeeNameForRules`.
    @Test func setPayeeNameReportsPendingPayee() {
        let rule = parseRule(
            conditions: #"[{"op":"contains","field":"imported_description","value":"woolies"}]"#,
            actions: #"[{"op":"set","field":"payee_name","value":"Woolworths"}]"#)

        let result = RulesEngine.apply(makeTransaction(importedPayee: "WOOLIES 123"), rules: [rule])

        #expect(result.pendingPayeeName == "Woolworths")
        #expect(result.transaction.payeeId == nil)
    }

    @Test func linkScheduleActionSetsSchedule() {
        let rule = parseRule(
            conditions: #"[{"op":"contains","field":"imported_description","value":"rent"}]"#,
            actions: #"[{"op":"link-schedule","value":"sched-1"}]"#)

        let (updated, changed) = applied(makeTransaction(importedPayee: "RENT JUNE"), rules: [rule])

        #expect(updated.schedule == "sched-1")
        #expect(changed.contains("schedule"))
    }

    @Test func deleteTransactionActionMarksResultDeleted() {
        let rule = parseRule(
            conditions: #"[{"op":"contains","field":"imported_description","value":"spam"}]"#,
            actions: #"[{"op":"delete-transaction","value":null}]"#)

        let result = RulesEngine.apply(makeTransaction(importedPayee: "SPAM CO"), rules: [rule])

        #expect(result.isDeleted)
        #expect(result.transaction.tombstone)
    }

    @Test func deleteTransactionLeavesNonMatchingTransactionsAlone() {
        let rule = parseRule(
            conditions: #"[{"op":"contains","field":"imported_description","value":"spam"}]"#,
            actions: #"[{"op":"delete-transaction","value":null}]"#)

        let result = RulesEngine.apply(makeTransaction(importedPayee: "Coffee Co"), rules: [rule])

        #expect(!result.isDeleted)
        #expect(!result.transaction.tombstone)
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
        let (updated, changed) = applied(tx, rules: [rule])
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
                    Rule.Condition(op: "contains", field: "imported_payee",
                                   value: .string("X"), options: nil)
                ],
                actions: [
                    Rule.Action(op: "set", field: "amount",
                                value: .number(bad), options: nil)
                ]
            )
            let tx = makeTransaction(importedPayee: "X-Co", amount: -500)
            // Must not trap; garbage values are dropped, the original amount
            // survives, and no change is reported for a write that never landed.
            let (updated, changed) = applied(tx, rules: [rule])
            #expect(updated.amount == -500)
            #expect(!changed.contains("amount"))
        }
    }

    // MARK: - Ordering

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
        let (updated, _) = applied(tx, rules: [def, pre])
        #expect(updated.payeeId == "payee-w")
        #expect(updated.categoryId == "cat-groceries")
    }

    @Test func postStageRunsLast() {
        let normal = parseRule(
            id: "def-1",
            conditions: #"[{"op":"contains","field":"imported_description","value":"coffee"}]"#,
            actions: #"[{"op":"set","field":"category","value":"cat-normal"}]"#)
        let post = parseRule(
            id: "post-1",
            stage: "post",
            conditions: #"[{"op":"contains","field":"imported_description","value":"coffee"}]"#,
            actions: #"[{"op":"set","field":"category","value":"cat-post"}]"#)

        let tx = makeTransaction(importedPayee: "Coffee Co")
        #expect(applied(tx, rules: [post, normal]).0.categoryId == "cat-post")
    }

    /// Within a stage, upstream ranks ascending by score so the most specific
    /// rule applies last and wins — whatever order the rules arrive in.
    @Test func moreSpecificRuleWinsRegardlessOfInputOrder() {
        let broad = parseRule(
            id: "r-b",
            conditions: #"[{"op":"contains","field":"imported_description","value":"coffee"}]"#,
            actions: #"[{"op":"set","field":"category","value":"cat-broad"}]"#)
        let exact = parseRule(
            id: "r-a",
            conditions: #"[{"op":"is","field":"imported_description","value":"coffee co"}]"#,
            actions: #"[{"op":"set","field":"category","value":"cat-exact"}]"#)

        let tx = makeTransaction(importedPayee: "Coffee Co")

        #expect(applied(tx, rules: [broad, exact]).0.categoryId == "cat-exact")
        #expect(applied(tx, rules: [exact, broad]).0.categoryId == "cat-exact")
    }

    // MARK: - Unsupported and malformed rules

    /// Splits aren't supported yet. The action is skipped, and skipping it must
    /// not corrupt the parent transaction's amount.
    @Test func splitActionsAreSkippedNotApplied() {
        let rule = parseRule(
            conditions: """
            [{"op":"contains","field":"imported_description","value":"shop"}]
            """,
            actions: """
            [{"op":"set-split-amount","value":500,"options":{"splitIndex":1,"method":"fixed-amount"}}]
            """
        )
        let (updated, changed) = applied(makeTransaction(importedPayee: "SHOP CO", amount: -2000),
                                        rules: [rule])

        #expect(updated.amount == -2000)
        #expect(changed.isEmpty)
    }

    /// A `set` carrying a Handlebars template or a formula is skipped whole —
    /// neither engine exists on iOS, and a half-applied template would be worse
    /// than no rule at all.
    @Test func templateAndFormulaActionsAreSkipped() {
        for options in [#"{"template":"{{payee}} auto"}"#, #"{"formula":"=amount*2"}"#] {
            let rule = parseRule(
                conditions: """
                [{"op":"contains","field":"imported_description","value":"X"}]
                """,
                actions: """
                [{"op":"set","field":"notes","value":"","options":\(options)}]
                """
            )
            let (updated, changed) = applied(makeTransaction(importedPayee: "X-Co", notes: "keep"),
                                             rules: [rule])
            #expect(updated.notes == "keep")
            #expect(changed.isEmpty)
        }
    }

    @Test func unknownActionOpIsIgnored() {
        let rule = parseRule(
            conditions: """
            [{"op":"contains","field":"imported_description","value":"X"}]
            """,
            actions: """
            [{"op":"teleport-transaction","value":"elsewhere"}]
            """
        )
        let tx = makeTransaction(importedPayee: "X-Co", payeeId: "payee-original")
        let (updated, changed) = applied(tx, rules: [rule])
        #expect(updated.payeeId == "payee-original")
        #expect(changed.isEmpty)
    }

    @Test func unknownConditionOpNeverMatches() {
        let rule = parseRule(
            conditions: """
            [{"op":"soundsLike","field":"imported_description","value":"X"}]
            """,
            actions: """
            [{"op":"set","field":"category","value":"cat-never"}]
            """
        )
        let (updated, _) = applied(makeTransaction(importedPayee: "X-Co"), rules: [rule])
        #expect(updated.categoryId == nil)
    }

    /// A rule with no conditions matches nothing — upstream's `evalConditions`
    /// returns false for an empty list rather than treating it as "always".
    @Test func ruleWithoutConditionsNeverFires() {
        let rule = Rule(
            id: "bad",
            stage: .default,
            conditionsOp: .and,
            conditions: [],
            actions: [
                Rule.Action(op: "set", field: "category", value: .string("cat-x"), options: nil)
            ]
        )
        let tx = makeTransaction(importedPayee: "X")
        let (updated, changed) = applied(tx, rules: [rule])
        #expect(updated.categoryId == nil)
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
        let (updated, _) = applied(tx, rules: [rule])
        #expect(updated.categoryId == "cat-tagged")
    }

    @Test func hasTagsDoesNotFireWhenATagIsMissing() {
        let rule = tagRule(op: "hasTags", value: "#work #urgent")
        let tx = makeTransaction(notes: "#work only")
        let (updated, _) = applied(tx, rules: [rule])
        #expect(updated.categoryId == nil)
    }

    @Test func hasAnyTagFiresOnAnySingleMatch() {
        let rule = tagRule(op: "hasAnyTag", value: "#work #urgent")
        let tx = makeTransaction(notes: "#urgent errand")
        let (updated, _) = applied(tx, rules: [rule])
        #expect(updated.categoryId == "cat-tagged")
    }

    @Test func tagMatchingSkipsHiddenAndPartialTags() {
        // ##work is a hidden tag ((?<!#) lookbehind) and #workout must not
        // count as a word-boundary match for #work.
        let rule = tagRule(op: "hasAnyTag", value: "#work")
        let tx = makeTransaction(notes: "##work #workout")
        let (updated, _) = applied(tx, rules: [rule])
        #expect(updated.categoryId == nil)
    }

    @Test func hasAnyTagDoesNotFireWithoutNotes() {
        let rule = tagRule(op: "hasAnyTag", value: "#work")
        let tx = makeTransaction(notes: nil)
        let (updated, _) = applied(tx, rules: [rule])
        #expect(updated.categoryId == nil)
    }
}
