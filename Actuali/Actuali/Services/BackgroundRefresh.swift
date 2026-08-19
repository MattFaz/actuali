import Foundation
import BackgroundTasks
import os

private let bgLog = Logger(subsystem: "com.mfazz.Actuali", category: "BackgroundRefresh")

/// Seam over BGTaskScheduler's submit so scheduling logic is testable.
protocol BackgroundTaskRequesting {
    func submit(_ taskRequest: BGTaskRequest) throws
}

extension BGTaskScheduler: BackgroundTaskRequesting {}

/// Seam over BGAppRefreshTask so handle() is testable (the system never
/// hands out instances outside a real background launch).
protocol BackgroundRefreshTask: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    func setTaskCompleted(success: Bool)
}

extension BGAppRefreshTask: BackgroundRefreshTask {}

/// Periodic background refresh: iOS wakes the app, we sync headlessly so the
/// app opens with fresh data, and notify about new transactions when the user
/// has opted in (the opt-in is enforced in NewTransactionNotifier, not here).
/// Runs for everyone; the OS-level Background App Refresh switch is the off
/// button.
enum BackgroundRefresh {

    /// Must stay listed in BGTaskSchedulerPermittedIdentifiers (both Info
    /// plists) — registering an unlisted identifier crashes at launch.
    static let taskIdentifier = "com.mfazz.ActualiOS.refresh"

    /// Hint to iOS for the earliest next run; actual timing is at the
    /// system's discretion and typically less frequent. Kept low — it is only
    /// a floor, and a high floor caps how many run windows iOS can offer.
    static let minimumInterval: TimeInterval = 60 * 60

    /// Floor used when a headless write couldn't be pushed. Shorter than
    /// `minimumInterval` so a queued Shortcut transaction gets a chance to
    /// reach the server before the user next opens the app — still only a hint,
    /// and iOS may ignore it entirely (issue #139).
    static let pendingWriteFlushInterval: TimeInterval = 15 * 60

    static func makeRequest(now: Date, earliestIn: TimeInterval = minimumInterval) -> BGAppRefreshTaskRequest {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = now.addingTimeInterval(earliestIn)
        return request
    }

    static func schedule(using scheduler: any BackgroundTaskRequesting = BGTaskScheduler.shared,
                         now: Date = Date(),
                         earliestIn: TimeInterval = minimumInterval,
                         defaults: UserDefaults = .standard) {
        let status = BackgroundRefreshStatus(defaults: defaults)
        status.lastScheduleAttempt = now
        do {
            try scheduler.submit(makeRequest(now: now, earliestIn: earliestIn))
            status.lastScheduleError = nil
        } catch {
            // Expected on simulator and when Background App Refresh is off.
            status.lastScheduleError = error.localizedDescription
            bgLog.error("Failed to schedule background refresh: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Must be called before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask)
        }
    }

    @discardableResult
    static func handle(_ task: any BackgroundRefreshTask,
                       scheduler: any BackgroundTaskRequesting = BGTaskScheduler.shared,
                       now: Date = Date(),
                       defaults: UserDefaults = .standard,
                       sync: @escaping @MainActor () async -> Bool = defaultSync) -> Task<Void, Never> {
        // Reschedule first so the chain survives regardless of the outcome.
        schedule(using: scheduler, now: now, defaults: defaults)
        // Recorded at fire time (not completion) — the row in Settings answers
        // "is iOS waking the app at all?", which this line alone proves.
        BackgroundRefreshStatus(defaults: defaults).lastRun = now
        bgLog.info("Background refresh fired, starting headless sync")
        // Wire expiration before the work exists so a fire in the gap between
        // starting the sync and installing the handler can never go unheard;
        // ExpirableWork replays an early cancel once the Task is attached.
        let work = ExpirableWork()
        task.expirationHandler = { work.cancel() }
        // BGTask's completion API is documented as thread-safe but the class
        // isn't Sendable, so wrap it to move it into the @MainActor sync Task
        // without tripping strict-concurrency's send check.
        let completer = TaskCompleter(task: task)
        // On expiration, cancellation propagates into URLSession so the sync
        // aborts quickly; the task body still runs to setTaskCompleted.
        let job = Task { @MainActor in
            let synced = await sync()
            bgLog.info("Background sync finished (budgetConfigured: \(synced))")
            completer.task.setTaskCompleted(success: synced)
        }
        work.attach(job)
        return job
    }

    @MainActor
    private static func defaultSync() async -> Bool {
        let store = BudgetStore.shared
        let synced = await store.syncInBackground()
        if synced {
            await store.notifyAboutSyncedTransactions()
        }
        return synced
    }
}

/// Carries a BGTask across into the sync Task. Its setTaskCompleted/expiration
/// APIs are thread-safe, but the class isn't Sendable — this wrapper makes the
/// move explicit and auditable.
private struct TaskCompleter: @unchecked Sendable {
    let task: any BackgroundRefreshTask
}

/// Lets the expiration handler be installed before the work Task exists: a
/// cancel that lands in between is remembered and replayed on attach.
private final class ExpirableWork: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        task?.cancel()
    }

    func attach(_ task: Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        self.task = task
        if cancelled { task.cancel() }
    }
}
