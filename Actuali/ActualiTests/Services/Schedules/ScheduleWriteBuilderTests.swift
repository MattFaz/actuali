import Foundation
import Testing
@testable import Actuali

/// Pins the exact rows and columns each schedule write touches. These shapes
/// have to match loot-core: a missing column here is a schedule the web app
/// renders blank or refuses to advance.
struct ScheduleWriteBuilderTests {

    private static let now: Int64 = 1_760_000_000_000
    private static let today = DayDate(yyyymmdd: 20260813)!

    private var fields: ScheduleFormFields {
        ScheduleFormFields(
            name: "  Rent  ",
            payeeId: "payee-1",
            accountId: "acct-1",
            amount: .fixed(-125_000),
            amountOp: .isApprox,
            date: .fixed(DayDate(yyyymmdd: 20260901)!),
            postsTransaction: true)
    }

    private func write(_ plan: ScheduleWritePlan, _ dataset: String) -> ScheduleWritePlan.RowWrite? {
        plan.writes.first { $0.dataset == dataset }
    }

    private func value(_ write: ScheduleWritePlan.RowWrite?, _ column: String) -> Any? {
        write?.fields.first { $0.column == column }?.value
    }

    // MARK: - create

    @Test func createWritesRuleNextDateAndSchedule() throws {
        let plan = try ScheduleWriteBuilder.createPlan(
            fields: fields, scheduleId: "s1", ruleId: "r1", nextDateRowId: "nd1",
            now: Self.now, today: Self.today)

        #expect(plan.scheduleId == "s1")
        #expect(plan.writes.map(\.dataset)
            == ["rules", "schedules_next_date", "schedules"])
    }

    @Test func createLinksTheRuleBackToTheSchedule() throws {
        let plan = try ScheduleWriteBuilder.createPlan(
            fields: fields, scheduleId: "s1", ruleId: "r1", nextDateRowId: "nd1",
            now: Self.now, today: Self.today)

        let actionsJSON = try #require(value(write(plan, "rules"), "actions") as? String)
        #expect(actionsJSON.contains("link-schedule"))
        #expect(actionsJSON.contains("s1"))
        #expect(value(write(plan, "rules"), "conditions_op") as? String == "and")
        #expect(value(write(plan, "schedules"), "rule") as? String == "r1")
    }

    /// Both halves of the pair start equal — that is what makes the local
    /// value the effective next date until something resets the base.
    @Test func createSetsBothHalvesOfTheNextDatePair() throws {
        let plan = try ScheduleWriteBuilder.createPlan(
            fields: fields, scheduleId: "s1", ruleId: "r1", nextDateRowId: "nd1",
            now: Self.now, today: Self.today)

        let nd = write(plan, "schedules_next_date")
        #expect(value(nd, "schedule_id") as? String == "s1")
        #expect(value(nd, "local_next_date") as? Int == 20260901)
        #expect(value(nd, "base_next_date") as? Int == 20260901)
        #expect(value(nd, "local_next_date_ts") as? Int64 == Self.now)
        #expect(value(nd, "base_next_date_ts") as? Int64 == Self.now)
    }

    @Test func createNormalizesTheName() throws {
        let plan = try ScheduleWriteBuilder.createPlan(
            fields: fields, scheduleId: "s1", ruleId: "r1", nextDateRowId: "nd1",
            now: Self.now, today: Self.today)
        #expect(value(write(plan, "schedules"), "name") as? String == "Rent")
    }

    @Test func createUsesTheNextOccurrenceForARecurrence() throws {
        var recurring = fields
        recurring.date = .recurring(try #require(RecurConfig(json: [
            "frequency": "monthly", "start": "2026-01-15", "interval": 1,
        ])))
        let plan = try ScheduleWriteBuilder.createPlan(
            fields: recurring, scheduleId: "s1", ruleId: "r1", nextDateRowId: "nd1",
            now: Self.now, today: Self.today)
        #expect(value(write(plan, "schedules_next_date"), "base_next_date") as? Int == 20260815)
    }

    // MARK: - update

    private func existingSchedule(
        conditions: String = """
            [{"op":"is","field":"account","value":"acct-1"},
             {"op":"isapprox","field":"date","value":"2026-08-13"},
             {"op":"isapprox","field":"amount","value":-125000}]
            """,
        actions: String = #"[{"op":"link-schedule","value":"s1"}]"#
    ) -> ScheduleSummary {
        ScheduleSummary(
            id: "s1", name: "Rent", ruleId: "r1",
            nextDate: DayDate(yyyymmdd: 20260813), nextDateRowId: "nd1",
            baseNextDateTs: 100, accountId: "acct-1", payeeId: nil,
            amount: .fixed(-125_000), amountOp: .isApprox, dateOp: "isapprox",
            dateCondition: .fixed(DayDate(yyyymmdd: 20260813)!),
            postsTransaction: true, completed: false,
            customUpcomingLength: nil, sortOrder: nil, isCustom: false,
            conditionsJSON: conditions, actionsJSON: actions)
    }

    /// Nothing about the account or the date moved, so the next date is left
    /// exactly where it is.
    @Test func updateWithoutAccountOrDateChangeDoesNotTouchTheNextDate() throws {
        var unchanged = fields
        unchanged.date = .fixed(DayDate(yyyymmdd: 20260813)!)
        unchanged.amount = .fixed(-99_000)

        let plan = try ScheduleWriteBuilder.updatePlan(
            schedule: existingSchedule(), fields: unchanged,
            now: Self.now, today: Self.today)

        #expect(write(plan, "schedules_next_date") == nil)
        #expect(plan.writes.map(\.dataset) == ["rules", "schedules"])
    }
    
    /// A recurrence written by the web omits the optional keys that
    /// `RecurConfig.jsonObject` always emits. Re-encoding it is not an edit, so
    /// saving an otherwise-untouched schedule must NOT reset the next date —
    /// doing so silently undoes a skip and re-anchors a missed schedule.
    @Test func reEncodingAWebWrittenRecurrenceIsNotADateChange() throws {
        // Exactly what Actual stores: no interval, no endMode, no weekend keys.
        let webRecurrence = """
            [{"op":"is","field":"account","value":"acct-1"},
             {"op":"isapprox","field":"date","value":
               {"frequency":"monthly","start":"2026-01-15"}},
             {"op":"isapprox","field":"amount","value":-125000}]
            """
        let schedule = existingSchedule(conditions: webRecurrence)

        // The form hands back the same recurrence, parsed and re-serialised.
        let parsed = try #require(RecurConfig(json: [
            "frequency": "monthly", "start": "2026-01-15",
        ]))
        var unchanged = fields
        unchanged.date = .recurring(parsed)

        let plan = try ScheduleWriteBuilder.updatePlan(
            schedule: schedule, fields: unchanged, now: Self.now, today: Self.today)

        #expect(write(plan, "schedules_next_date") == nil)
        #expect(plan.writes.map(\.dataset) == ["rules", "schedules"])
    }

    /// The guard above must not go so far that a real recurrence edit stops
    /// resetting the next date.
    @Test func changingTheRecurrenceStillResetsTheNextDate() throws {
        let schedule = existingSchedule(conditions: """
            [{"op":"is","field":"account","value":"acct-1"},
             {"op":"isapprox","field":"date","value":
               {"frequency":"monthly","start":"2026-01-15"}},
             {"op":"isapprox","field":"amount","value":-125000}]
            """)

        // Same start, different interval — a genuine change.
        let edited = try #require(RecurConfig(json: [
            "frequency": "monthly", "start": "2026-01-15", "interval": 3,
        ]))
        var moved = fields
        moved.date = .recurring(edited)

        let plan = try ScheduleWriteBuilder.updatePlan(
            schedule: schedule, fields: moved, now: Self.now, today: Self.today)

        #expect(write(plan, "schedules_next_date") != nil)
    }

    @Test func changingTheDateResetsTheBaseNextDate() throws {
        var moved = fields
        moved.date = .fixed(DayDate(yyyymmdd: 20261001)!)

        let plan = try ScheduleWriteBuilder.updatePlan(
            schedule: existingSchedule(), fields: moved,
            now: Self.now, today: Self.today)

        let nd = write(plan, "schedules_next_date")
        #expect(value(nd, "base_next_date") as? Int == 20261001)
        #expect(value(nd, "base_next_date_ts") as? Int64 == Self.now)
        // The reset branch never writes the local half.
        #expect(value(nd, "local_next_date") == nil)
    }

    @Test func changingTheAccountResetsTheNextDate() throws {
        var moved = fields
        moved.accountId = "acct-2"
        moved.date = .fixed(DayDate(yyyymmdd: 20260813)!)

        let plan = try ScheduleWriteBuilder.updatePlan(
            schedule: existingSchedule(), fields: moved,
            now: Self.now, today: Self.today)
        #expect(write(plan, "schedules_next_date") != nil)
    }

    @Test func resetCanBeForced() throws {
        var unchanged = fields
        unchanged.date = .fixed(DayDate(yyyymmdd: 20260813)!)

        let plan = try ScheduleWriteBuilder.updatePlan(
            schedule: existingSchedule(), fields: unchanged,
            now: Self.now, today: Self.today, resetRequested: true)
        #expect(write(plan, "schedules_next_date") != nil)
    }

    /// The update must never change which rule a schedule points at —
    /// upstream throws outright if asked to.
    @Test func updateNeverRewritesTheRuleLink() throws {
        let plan = try ScheduleWriteBuilder.updatePlan(
            schedule: existingSchedule(), fields: fields,
            now: Self.now, today: Self.today)
        #expect(value(write(plan, "schedules"), "rule") == nil)
    }

    @Test func updateWritesActionsOnlyWhenTheAmountActionDrifted() throws {
        let plain = try ScheduleWriteBuilder.updatePlan(
            schedule: existingSchedule(), fields: fields,
            now: Self.now, today: Self.today)
        #expect(value(write(plain, "rules"), "actions") == nil)

        let withAction = existingSchedule(
            actions: """
                [{"op":"link-schedule","value":"s1"},
                 {"op":"set","field":"amount","value":-1}]
                """)
        let synced = try ScheduleWriteBuilder.updatePlan(
            schedule: withAction, fields: fields, now: Self.now, today: Self.today)
        let actionsJSON = try #require(value(write(synced, "rules"), "actions") as? String)
        #expect(actionsJSON.contains("-125000"))
    }

    @Test func updateRepairsAMissingNextDateRow() throws {
        var broken = existingSchedule()
        broken.nextDateRowId = nil

        let plan = try ScheduleWriteBuilder.updatePlan(
            schedule: broken, fields: fields, now: Self.now, today: Self.today,
            resetRequested: true, newNextDateRowId: "nd-new")

        let nd = write(plan, "schedules_next_date")
        #expect(nd?.row == "nd-new")
        // A fresh row needs its owner and both halves, not just the base.
        #expect(value(nd, "schedule_id") as? String == "s1")
        #expect(value(nd, "local_next_date") as? Int == 20260901)
        #expect(value(nd, "base_next_date") as? Int == 20260901)
    }

    // MARK: - delete

    @Test func deleteTombstonesBothTheScheduleAndItsRule() {
        let plan = ScheduleWriteBuilder.deletePlan(schedule: existingSchedule())
        #expect(plan.writes.count == 2)
        #expect(value(write(plan, "schedules"), "tombstone") as? Int == 1)
        #expect(value(write(plan, "rules"), "tombstone") as? Int == 1)
        // A delete touches no conditions, so the path cache is left alone.
        #expect(plan.conditions == nil)
    }

    @Test func deleteWithoutARuleStillTombstonesTheSchedule() {
        var orphan = existingSchedule()
        orphan.ruleId = nil
        let plan = ScheduleWriteBuilder.deletePlan(schedule: orphan)
        #expect(plan.writes.count == 1)
        #expect(plan.writes[0].dataset == "schedules")
    }

    // MARK: - next date

    @Test func resetMovesTheBaseAndNonResetMovesTheLocalOverride() throws {
        let schedule = existingSchedule()
        let target = DayDate(yyyymmdd: 20261101)!

        let reset = try #require(ScheduleWriteBuilder.nextDatePlan(
            schedule: schedule, newNextDate: target, reset: true, now: Self.now))
        #expect(value(write(reset, "schedules_next_date"), "base_next_date") as? Int == 20261101)
        #expect(value(write(reset, "schedules_next_date"), "base_next_date_ts") as? Int64 == Self.now)

        let local = try #require(ScheduleWriteBuilder.nextDatePlan(
            schedule: schedule, newNextDate: target, reset: false, now: Self.now))
        #expect(value(write(local, "schedules_next_date"), "local_next_date") as? Int == 20261101)
        // Pinned to the CURRENT base timestamp, not to now — that is what keeps
        // the override effective under the v_schedules rule.
        #expect(value(write(local, "schedules_next_date"), "local_next_date_ts") as? Int64 == 100)
    }
}
