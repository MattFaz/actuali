import Foundation
import os

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "SchedulePoster")

/// The two server-visible writes the poster performs, abstracted so tests can
/// record them. `SyncClient` is the production conformance.
protocol SchedulePostingActions {
    func createTransaction(_ transaction: Transaction) async throws
    func advanceScheduleNextDate(nextDateRowId: String, newNextDate: Int, baseNextDateTs: Int64?) async throws
}

/// Posts due automatic schedules and advances their next dates.
/// Mirrors the posting half of loot-core `advanceSchedulesService`.
///
/// Every write here lands on the user's real Actual server, so failure
/// behavior is conservative throughout: a fetch error is a logged no-op, a
/// schedule-level error skips only that schedule, and the once-per-day gate
/// is set only after a pass with zero schedule-level errors — a dirty pass
/// retries on the next trigger the same day.
///
/// An actor so overlapping `runIfNeeded` calls (e.g. foreground flapping)
/// can't interleave: the UserDefaults gate only moves at the END of a clean
/// pass, so two concurrent passes would both clear it, and pass B's
/// `hasTransaction` dedup check can run before pass A's `createTransaction`
/// (a network round-trip) commits — double-posting to the user's real server.
/// The synchronous, actor-isolated `isRunning` check-and-set below closes
/// that window.
actor SchedulePoster {
    let database: BudgetDatabase
    let actions: any SchedulePostingActions
    let defaults: UserDefaults

    /// In-flight guard; see the actor rationale above.
    private var isRunning = false

    /// Hard stop for a single schedule's catch-up loop. A schedule can fall
    /// arbitrarily far behind (long-unopened budget); 200 occurrences is far
    /// beyond anything sane to backfill and guards against recurrence bugs
    /// spinning forever.
    private static let iterationCap = 200

    init(database: BudgetDatabase, actions: any SchedulePostingActions, defaults: UserDefaults = .standard) {
        self.database = database
        self.actions = actions
        self.defaults = defaults
    }

    private func gateKey(_ budgetId: String) -> String { "lastScheduleRun-\(budgetId)" }

    /// Post every due occurrence of every postable schedule, advancing next
    /// dates as it goes. At most one CLEAN pass per calendar day per budget;
    /// only a pass with zero schedule-level errors sets the gate. A call that
    /// overlaps an in-flight pass returns 0 without running.
    /// - Returns: number of transactions posted.
    @discardableResult
    func runIfNeeded(budgetId: String, today: DayDate = .today()) async -> Int {
        assert(!budgetId.isEmpty, "empty budgetId would collapse the once-per-day gate across budgets")
        guard !isRunning else { return 0 }
        isRunning = true
        defer { isRunning = false }

        guard defaults.integer(forKey: gateKey(budgetId)) != today.yyyymmdd else { return 0 }
        let schedules: [Schedule]
        do {
            schedules = try database.fetchPostableSchedules()
        } catch {
            // No gate write: the next trigger (same day included) retries.
            logger.error("fetchPostableSchedules failed - skipping pass: \(error, privacy: .public)")
            return 0
        }

        var posted = 0
        var clean = true
        for schedule in schedules {
            do {
                posted += try await process(schedule, today: today)
            } catch {
                // NEVER abort the pass — other schedules must still post.
                clean = false
                logger.error("Schedule \(schedule.id, privacy: .public) failed to post/advance: \(error, privacy: .public)")
            }
        }
        if clean {
            defaults.set(today.yyyymmdd, forKey: gateKey(budgetId))
        }
        if posted > 0 {
            logger.info("Posted \(posted, privacy: .public) scheduled transaction(s)")
        }
        return posted
    }

    /// Post all due occurrences of one schedule, advancing after each.
    private func process(_ schedule: Schedule, today: DayDate) async throws -> Int {
        var current = schedule.nextDate
        var posted = 0
        var iterations = 0
        while current <= today, iterations < Self.iterationCap {
            iterations += 1

            // Dedup guard (loot-core parity): an alive transaction already
            // linked to this schedule on/after the occurrence means the user
            // (or another client) covered it — advance without posting.
            let paid = try database.hasTransaction(scheduleId: schedule.id, onOrAfter: current.yyyymmdd)
            if !paid {
                var txn = Transaction(
                    id: UUID().uuidString.lowercased(),
                    accountId: schedule.accountId,
                    date: current.yyyymmdd,
                    amount: schedule.amount?.postAmount ?? 0,
                    payeeId: schedule.payeeId,
                    payeeName: nil,
                    categoryId: schedule.categoryId,
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
                txn.schedule = schedule.id
                try await actions.createTransaction(txn)
                posted += 1
            }

            // One-off and unsupported-recurrence schedules post at most once
            // and never advance; completion (or the advance the port can't
            // compute) is left to the web app (loot-core parity — its advance
            // throws on such shapes and the service swallows it after posting).
            guard case .recurring(let config) = schedule.dateCondition else { break }

            guard let next = ScheduleRecurrence.nextOccurrence(config: config, onOrAfter: current.adding(days: 1)),
                  next > current
            else { break }   // ended, or weekend-solve pinned the date: treat as not-advanced and stop

            try await actions.advanceScheduleNextDate(
                nextDateRowId: schedule.nextDateRowId,
                newNextDate: next.yyyymmdd,
                baseNextDateTs: schedule.baseNextDateTs)
            current = next
        }
        return posted
    }
}
