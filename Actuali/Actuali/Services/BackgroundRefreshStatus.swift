import Foundation

/// Background refresh diagnostics, persisted device-locally so Settings can
/// show whether iOS is actually waking the app (the task's own info-level log
/// lines rotate out of the persisted log store within hours, so this is the
/// only durable evidence). Recording both the ask (schedule attempt) and the
/// wake (last run) separates "we never asked" from "we asked and iOS never
/// woke us" — the two look identical from a bare last-run timestamp.
struct BackgroundRefreshStatus {

    static let lastRunKey = "backgroundRefreshLastRun"
    static let lastScheduleAttemptKey = "backgroundRefreshLastScheduleAttempt"
    static let lastScheduleErrorKey = "backgroundRefreshLastScheduleError"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// When the background refresh task last fired.
    var lastRun: Date? {
        get { defaults.object(forKey: Self.lastRunKey) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Self.lastRunKey) }
    }

    /// When we last asked BGTaskScheduler for a wake, whether or not the
    /// submit succeeded.
    var lastScheduleAttempt: Date? {
        get { defaults.object(forKey: Self.lastScheduleAttemptKey) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Self.lastScheduleAttemptKey) }
    }

    /// Why the last submit failed; nil after a successful submit.
    var lastScheduleError: String? {
        get { defaults.string(forKey: Self.lastScheduleErrorKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.lastScheduleErrorKey) }
    }
}
