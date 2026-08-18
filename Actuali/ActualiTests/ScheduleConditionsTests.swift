import Foundation
import Testing
@testable import Actuali

/// Pins the condition build/merge logic. This is the code that decides what a
/// schedule looks like on the server, so the cases that matter most are the
/// ones about NOT destroying data the phone can't display.
struct ScheduleConditionsTests {

    private let fixedDate = ScheduleDateCondition.fixed(DayDate(yyyymmdd: 20260813)!)

    private func fields(
        payee: String? = "payee-1",
        account: String? = "acct-1",
        amount: ScheduledAmount? = .fixed(-1250),
        amountOp: ScheduleAmountOp = .isApprox
    ) -> ScheduleFormFields {
        ScheduleFormFields(
            name: "Rent", payeeId: payee, accountId: account,
            amount: amount, amountOp: amountOp, date: fixedDate)
    }

    // MARK: - extract

    @Test func extractFindsTheFourConditions() {
        let conditions: [[String: Any]] = [
            ["op": "is", "field": "account", "value": "acct-1"],
            ["op": "contains", "field": "notes", "value": "x"],
            ["op": "is", "field": "payee", "value": "payee-1"],
            ["op": "isapprox", "field": "date", "value": "2026-08-13"],
            ["op": "isbetween", "field": "amount", "value": ["num1": 1, "num2": 2]],
        ]
        let indices = ScheduleConditions.extract(conditions)
        #expect(indices.account == 0)
        #expect(indices.payee == 2)
        #expect(indices.date == 3)
        #expect(indices.amount == 4)
    }

    @Test func extractFallsBackToInternalFieldNames() {
        let conditions: [[String: Any]] = [
            ["op": "is", "field": "acct", "value": "acct-1"],
            ["op": "is", "field": "description", "value": "payee-1"],
        ]
        let indices = ScheduleConditions.extract(conditions)
        #expect(indices.account == 0)
        #expect(indices.payee == 1)
    }

    @Test func publicFieldNamesWinOverInternalOnes() {
        let conditions: [[String: Any]] = [
            ["op": "is", "field": "acct", "value": "old"],
            ["op": "is", "field": "account", "value": "new"],
        ]
        #expect(ScheduleConditions.extract(conditions).account == 1)
    }

    // MARK: - build

    @Test func buildProducesTheFourConditionsInOrder() throws {
        let built = try ScheduleConditions.build(fields: fields(), existing: [])
        #expect(built.count == 4)
        #expect(built.map { $0["field"] as? String } == ["payee", "account", "date", "amount"])
        #expect(built[3]["op"] as? String == "isapprox")
    }

    /// A payee condition is written even with no payee, so the slot exists.
    @Test func buildAlwaysEmitsAPayeeCondition() throws {
        let built = try ScheduleConditions.build(fields: fields(payee: nil), existing: [])
        #expect(built[0]["field"] as? String == "payee")
        #expect(built[0]["value"] is NSNull)
    }

    @Test func buildOmitsAnAccountConditionWhenThereIsNoAccount() throws {
        let built = try ScheduleConditions.build(fields: fields(account: nil), existing: [])
        #expect(!built.contains { $0["field"] as? String == "account" })
    }

    /// An existing condition keeps its operator — an exact-date schedule set up
    /// on the web must not silently become approximate after a phone edit.
    @Test func buildPreservesAnExistingOperator() throws {
        let existing: [[String: Any]] = [
            ["op": "is", "field": "date", "value": "2026-01-01"],
        ]
        let built = try ScheduleConditions.build(fields: fields(), existing: existing)
        let date = try #require(built.first { $0["field"] as? String == "date" })
        #expect(date["op"] as? String == "is")
        #expect(date["value"] as? String == "2026-08-13")
    }

    /// Amount is the exception: the form owns the operator, so it is rewritten.
    @Test func buildOverwritesTheAmountOperator() throws {
        let existing: [[String: Any]] = [
            ["op": "isbetween", "field": "amount", "value": ["num1": 1, "num2": 2]],
        ]
        let built = try ScheduleConditions.build(
            fields: fields(amountOp: .isExactly), existing: existing)
        let amount = try #require(built.first { $0["field"] as? String == "amount" })
        #expect(amount["op"] as? String == "is")
        #expect((amount["value"] as? NSNumber)?.intValue == -1250)
    }

    @Test func buildRequiresADate() {
        var f = fields()
        f.date = nil
        #expect(throws: ScheduleWriteError.dateRequired) {
            try ScheduleConditions.build(fields: f, existing: [])
        }
    }

    @Test func buildRequiresAnAmount() {
        #expect(throws: ScheduleWriteError.amountRequired) {
            try ScheduleConditions.build(fields: fields(amount: nil), existing: [])
        }
    }

    // MARK: - merge

    /// The whole point of the merge: conditions the schedule doesn't own
    /// survive an edit made on the phone.
    @Test func mergeKeepsCustomConditionsInPlace() throws {
        let existing: [[String: Any]] = [
            ["op": "is", "field": "account", "value": "old-acct"],
            ["op": "contains", "field": "notes", "value": "keep me"],
            ["op": "is", "field": "amount", "value": -1],
        ]
        let scheduleConditions = try ScheduleConditions.build(
            fields: fields(), existing: existing)
        let merged = ScheduleConditions.merge(
            existing: existing, scheduleConditions: scheduleConditions)

        // The custom condition kept both its content and its position.
        #expect(merged[1]["field"] as? String == "notes")
        #expect(merged[1]["value"] as? String == "keep me")
        // The account was replaced in place, not appended.
        #expect(merged[0]["value"] as? String == "acct-1")
        // Payee and date had no old slot, so they were appended.
        #expect(merged.count == 5)
    }

    @Test func mergeAppendsConditionsThatHadNoCounterpart() throws {
        let existing: [[String: Any]] = [
            ["op": "is", "field": "amount", "value": -1],
        ]
        let built = try ScheduleConditions.build(fields: fields(), existing: existing)
        let merged = ScheduleConditions.merge(existing: existing, scheduleConditions: built)
        #expect(merged.count == 4)
        #expect(merged[0]["field"] as? String == "amount")
    }

    // MARK: - actions

    @Test func syncedActionsRewritesAPlainSetAmountAction() {
        let conditions: [[String: Any]] = [
            ["op": "is", "field": "amount", "value": -500],
        ]
        let actions: [[String: Any]] = [
            ["op": "link-schedule", "value": "sched-1"],
            ["op": "set", "field": "amount", "value": -100],
        ]
        let updated = ScheduleConditions.syncedActions(conditions: conditions, actions: actions)
        #expect((updated?[1]["value"] as? NSNumber)?.intValue == -500)
    }

    @Test func syncedActionsLeavesTemplatedActionsAlone() {
        let conditions: [[String: Any]] = [["op": "is", "field": "amount", "value": -500]]
        let actions: [[String: Any]] = [
            ["op": "set", "field": "amount", "value": -100,
             "options": ["template": "{{foo}}"]],
        ]
        #expect(ScheduleConditions.syncedActions(conditions: conditions, actions: actions) == nil)
    }

    @Test func syncedActionsReturnsNilWhenNothingChanged() {
        let conditions: [[String: Any]] = [["op": "is", "field": "amount", "value": -500]]
        let actions: [[String: Any]] = [["op": "set", "field": "amount", "value": -500]]
        #expect(ScheduleConditions.syncedActions(conditions: conditions, actions: actions) == nil)
    }

    @Test func syncedActionsUsesTheAverageOfARange() {
        let conditions: [[String: Any]] = [
            ["op": "isbetween", "field": "amount", "value": ["num1": -300, "num2": -100]],
        ]
        let actions: [[String: Any]] = [["op": "set", "field": "amount", "value": 0]]
        let updated = ScheduleConditions.syncedActions(conditions: conditions, actions: actions)
        #expect((updated?[0]["value"] as? NSNumber)?.intValue == -200)
    }

    // MARK: - JSON paths

    @Test func jsonPathsPointAtTheRightIndices() {
        let conditions: [[String: Any]] = [
            ["op": "contains", "field": "notes", "value": "x"],
            ["op": "is", "field": "payee", "value": "p"],
            ["op": "is", "field": "account", "value": "a"],
            ["op": "is", "field": "date", "value": "2026-08-13"],
            ["op": "is", "field": "amount", "value": -1],
        ]
        let paths = ScheduleConditions.jsonPaths(for: conditions)
        #expect(paths.payee == "$[1]")
        #expect(paths.account == "$[2]")
        #expect(paths.date == "$[3]")
        #expect(paths.amount == "$[4]")
    }

    @Test func missingConditionsHaveNoPath() {
        let paths = ScheduleConditions.jsonPaths(for: [
            ["op": "is", "field": "amount", "value": -1],
        ])
        #expect(paths.amount == "$[0]")
        #expect(paths.payee == nil)
        #expect(paths.account == nil)
        #expect(paths.date == nil)
    }

    // MARK: - next date

    @Test func oneOffDatesAreReturnedEvenWhenPast() {
        let past = DayDate(yyyymmdd: 20200101)!
        #expect(ScheduleConditions.nextDate(
            for: .fixed(past), from: DayDate(yyyymmdd: 20260813)!) == past)
    }

    @Test func recurringDatesAdvanceToTheNextOccurrence() throws {
        let config = try #require(RecurConfig(json: [
            "frequency": "monthly", "start": "2026-01-15", "interval": 1,
        ]))
        let next = ScheduleConditions.nextDate(
            for: .recurring(config), from: DayDate(yyyymmdd: 20260813)!)
        #expect(next == DayDate(yyyymmdd: 20260815))
    }
}
