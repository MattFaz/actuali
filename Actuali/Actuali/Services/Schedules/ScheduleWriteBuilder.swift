import Foundation

/// Exactly which rows and columns a schedule write touches, computed as pure
/// data.
///
/// The row shapes are the part of this feature that has to match loot-core
/// byte for byte — a wrong column leaves a schedule the web renders blank.
/// Keeping the plan free of the sync client, the network and the clock makes
/// that shape directly assertable in tests.
struct ScheduleWritePlan {
    struct RowWrite {
        let dataset: String
        let row: String
        let fields: [(column: String, value: (any Sendable)?)]
    }

    var scheduleId: String
    var writes: [RowWrite]
    /// Final rule conditions, for the local JSON-path cache. Nil when the plan
    /// doesn't touch the rule (a delete, or a schedule-columns-only update).
    var conditions: [[String: Any]]?
}

enum ScheduleWriteBuilder {

    /// Port of loot-core `createSchedule`: one rule, one next-date row, one
    /// schedule row.
    ///
    /// Ids and `now` are injected so a test can assert the whole plan.
    static func createPlan(
        fields: ScheduleFormFields,
        scheduleId: String,
        ruleId: String,
        nextDateRowId: String,
        now: Int64,
        today: DayDate = .today()
    ) throws -> ScheduleWritePlan {
        let conditions = try ScheduleConditions.build(fields: fields, existing: [])
        guard let date = fields.date else { throw ScheduleWriteError.dateRequired }
        guard let nextDate = ScheduleConditions.nextDate(for: date, from: today) else {
            throw ScheduleWriteError.unsupportedRecurrence
        }

        let actions: [[String: Any]] = [["op": "link-schedule", "value": scheduleId]]

        return ScheduleWritePlan(
            scheduleId: scheduleId,
            writes: [
                .init(dataset: "rules", row: ruleId, fields: [
                    ("stage", nil),
                    ("conditions_op", "and"),
                    ("conditions", try ScheduleConditions.serialize(conditions)),
                    ("actions", try ScheduleConditions.serialize(actions)),
                    ("tombstone", 0),
                ]),
                // Both halves of the next-date pair start equal, which is what
                // makes the local value the effective one until something
                // resets the base.
                .init(dataset: "schedules_next_date", row: nextDateRowId, fields: [
                    ("schedule_id", scheduleId),
                    ("local_next_date", nextDate.yyyymmdd),
                    ("local_next_date_ts", now),
                    ("base_next_date", nextDate.yyyymmdd),
                    ("base_next_date_ts", now),
                ]),
                .init(dataset: "schedules", row: scheduleId, fields: [
                    ("rule", ruleId),
                    ("name", fields.normalizedName),
                    ("posts_transaction", fields.postsTransaction ? 1 : 0),
                    ("custom_upcoming_length", fields.customUpcomingLength),
                    ("completed", 0),
                    ("tombstone", 0),
                ]),
            ],
            conditions: conditions)
    }

    /// Port of loot-core `updateSchedule`.
    ///
    /// `resetRequested` forces the next date to be recomputed; otherwise it is
    /// recomputed only when the account or the date condition actually
    /// changed. Account counts because a schedule on a closed account is never
    /// advanced, so moving it to an open one has to catch it up.
    static func updatePlan(
        schedule: ScheduleSummary,
        fields: ScheduleFormFields,
        now: Int64,
        today: DayDate = .today(),
        resetRequested: Bool = false,
        newNextDateRowId: @autoclosure () -> String = UUID().uuidString.lowercased(),
        newRuleId: @autoclosure () -> String = UUID().uuidString.lowercased()
    ) throws -> ScheduleWritePlan {
        let existingConditions = ScheduleConditions.parse(schedule.conditionsJSON)
        let existingActions = ScheduleConditions.parse(schedule.actionsJSON)

        let scheduleConditions = try ScheduleConditions.build(
            fields: fields, existing: existingConditions)
        let merged = ScheduleConditions.merge(
            existing: existingConditions, scheduleConditions: scheduleConditions)

        var writes: [ScheduleWritePlan.RowWrite] = []

        // A schedule whose rule went missing gets a fresh one rather than
        // dropping every field change on the floor (upstream fixRuleForSchedule).
        // This is the one case where writing `rule` is correct — upstream's
        // "you cannot change the rule" guard is about swapping a live rule.
        let ruleId = schedule.ruleId ?? newRuleId()
        var ruleFields: [(column: String, value: (any Sendable)?)] = [
            ("conditions", try ScheduleConditions.serialize(merged)),
        ]
        if schedule.ruleId == nil {
            ruleFields.append(("stage", nil))
            ruleFields.append(("conditions_op", "and"))
            ruleFields.append(("actions", try ScheduleConditions.serialize(
                [["op": "link-schedule", "value": schedule.id]])))
            ruleFields.append(("tombstone", 0))
        } else if let actions = ScheduleConditions.syncedActions(
            conditions: merged, actions: existingActions) {
            ruleFields.append(("actions", try ScheduleConditions.serialize(actions)))
        }
        writes.append(.init(dataset: "rules", row: ruleId, fields: ruleFields))

        // Next date: reset when forced, or when account/date changed.
        let oldIndices = ScheduleConditions.extract(existingConditions)
        let newIndices = ScheduleConditions.extract(merged)
        let accountChanged = !ScheduleConditions.conditionsEqual(
            ScheduleConditions.condition(at: oldIndices.account, in: existingConditions),
            ScheduleConditions.condition(at: newIndices.account, in: merged))
        
        let oldDateCondition = ScheduleConditions.condition(at: oldIndices.date, in: existingConditions)
        let newDateCondition = ScheduleConditions.condition(at: newIndices.date, in: merged)
        // Compare the date SEMANTICALLY, not as raw JSON. A config written by
        // the web omits keys `RecurConfig.jsonObject` always emits (interval,
        // skipWeekend, weekendSolveMode, endMode), so a byte comparison reports
        // a change on every save — resetting the next date and undoing a skip.
        let dateChanged = (oldDateCondition?["op"] as? String) != (newDateCondition?["op"] as? String)
            || Self.parsedDate(oldDateCondition) != Self.parsedDate(newDateCondition)

        if resetRequested || accountChanged || dateChanged,
           let date = fields.date,
           let nextDate = ScheduleConditions.nextDate(for: date, from: today) {
            // A schedule whose next-date row went missing gets a fresh one
            // rather than silently skipping the write; `schedule_id` is only
            // needed on that new row.
            let rowId = schedule.nextDateRowId ?? newNextDateRowId()
            var fields: [(column: String, value: (any Sendable)?)] = []
            if schedule.nextDateRowId == nil {
                fields.append(("schedule_id", schedule.id))
                fields.append(("local_next_date", nextDate.yyyymmdd))
                fields.append(("local_next_date_ts", now))
            }
            fields.append(("base_next_date", nextDate.yyyymmdd))
            fields.append(("base_next_date_ts", now))
            writes.append(.init(dataset: "schedules_next_date", row: rowId, fields: fields))
        }

        var scheduleFields: [(column: String, value: (any Sendable)?)] = [
            ("name", fields.normalizedName),
            ("posts_transaction", fields.postsTransaction ? 1 : 0),
            ("custom_upcoming_length", fields.customUpcomingLength),
        ]
        if schedule.ruleId == nil { scheduleFields.append(("rule", ruleId)) }
        writes.append(.init(dataset: "schedules", row: schedule.id, fields: scheduleFields))

        return ScheduleWritePlan(scheduleId: schedule.id, writes: writes, conditions: merged)
    }

    /// Port of loot-core `deleteSchedule`, as tombstones.
    ///
    /// loot-core hard-deletes both rows locally and lets the CRDT layer carry
    /// the tombstone; in Actuali the tombstone IS the write. The rule goes too
    /// — an orphaned rule would keep matching imported transactions forever.
    static func deletePlan(schedule: ScheduleSummary) -> ScheduleWritePlan {
        var writes: [ScheduleWritePlan.RowWrite] = [
            .init(dataset: "schedules", row: schedule.id, fields: [("tombstone", 1)]),
        ]
        if let ruleId = schedule.ruleId {
            writes.append(.init(dataset: "rules", row: ruleId, fields: [("tombstone", 1)]))
        }
        return ScheduleWritePlan(scheduleId: schedule.id, writes: writes, conditions: nil)
    }

    /// Set a schedule's next date. Port of loot-core `setNextDate`.
    ///
    /// `reset: true` moves the canonical base (a user-visible change of when
    /// the schedule is next due). `reset: false` moves only the local
    /// override, pinning `local_next_date_ts` to the CURRENT
    /// `base_next_date_ts` so the override stays effective under the
    /// v_schedules rule until another client resets the base — the branch the
    /// auto-poster already uses.
    static func nextDatePlan(
        schedule: ScheduleSummary,
        newNextDate: DayDate,
        reset: Bool,
        now: Int64
    ) -> ScheduleWritePlan? {
        guard let rowId = schedule.nextDateRowId else { return nil }
        let fields: [(column: String, value: (any Sendable)?)] = reset
            ? [("base_next_date", newNextDate.yyyymmdd), ("base_next_date_ts", now)]
            : [("local_next_date", newNextDate.yyyymmdd),
               ("local_next_date_ts", schedule.baseNextDateTs)]
        return ScheduleWritePlan(
            scheduleId: schedule.id,
            writes: [.init(dataset: "schedules_next_date", row: rowId, fields: fields)],
            conditions: nil)
    }

    /// Update only the schedule row's own columns (complete / restart, and the
    /// lifecycle actions in M5).
    static func scheduleColumnsPlan(
        scheduleId: String,
        fields: [(column: String, value: (any Sendable)?)]
    ) -> ScheduleWritePlan {
        ScheduleWritePlan(
            scheduleId: scheduleId,
            writes: [.init(dataset: "schedules", row: scheduleId, fields: fields)],
            conditions: nil)
    }
    
    /// Parse a raw date condition into its semantic form so two encodings of
    /// the same recurrence compare equal. `RecurConfig(json:)` normalises the
    /// optional fields, which is exactly the normalisation this needs.
    private static func parsedDate(_ condition: [String: Any]?) -> ScheduleDateCondition? {
        guard let value = condition?["value"] else { return nil }
        if let iso = value as? String { return DayDate(iso: iso).map(ScheduleDateCondition.fixed) }
        if let json = value as? [String: Any], let config = RecurConfig(json: json) {
            return .recurring(config)
        }
        return nil
    }
}
