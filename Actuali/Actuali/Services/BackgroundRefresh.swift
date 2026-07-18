import Foundation
import BackgroundTasks
import os

private let bgLog = Logger(subsystem: "com.mfazz.Actuali", category: "BackgroundRefresh")

/// Seam over BGTaskScheduler's submit so scheduling logic is testable.
protocol BackgroundTaskRequesting {
    func submit(_ taskRequest: BGTaskRequest) throws
}

extension BGTaskScheduler: BackgroundTaskRequesting {}

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
    /// system's discretion and typically less frequent.
    static let minimumInterval: TimeInterval = 4 * 60 * 60

    static func makeRequest(now: Date) -> BGAppRefreshTaskRequest {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = now.addingTimeInterval(minimumInterval)
        return request
    }

    static func schedule(using scheduler: BackgroundTaskRequesting = BGTaskScheduler.shared,
                         now: Date = Date()) {
        do {
            try scheduler.submit(makeRequest(now: now))
        } catch {
            // Expected on simulator and when Background App Refresh is off.
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

    static func handle(_ task: BGAppRefreshTask) {
        // Reschedule first so the chain survives regardless of the outcome.
        schedule()
        bgLog.info("Background refresh fired, starting headless sync")
        let work = Task { @MainActor in
            let store = BudgetStore.shared
            let synced = await store.syncInBackground()
            if synced {
                let fresh = await store.detectNewTransactionsForNotification()
                // The sync just refreshed the accounts cache, so names are
                // current even on a cold background launch.
                let accountNames = store.accounts.reduce(into: [String: String]()) {
                    $0[$1.id] = $1.name
                }
                await NewTransactionNotifier.notify(about: fresh, currencyCode: store.currencyCode,
                                                    accountNames: accountNames)
            }
            bgLog.info("Background sync finished (budgetConfigured: \(synced))")
            task.setTaskCompleted(success: synced)
        }
        // On expiration, cancellation propagates into URLSession so the sync
        // aborts quickly; the task body still runs to setTaskCompleted.
        task.expirationHandler = { work.cancel() }
    }
}
