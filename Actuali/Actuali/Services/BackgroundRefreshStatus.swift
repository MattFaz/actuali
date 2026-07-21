import Foundation

/// When the background refresh task last fired, persisted device-locally so
/// Settings can show whether iOS is actually waking the app (the task's own
/// info-level log lines rotate out of the persisted log store within hours,
/// so this is the only durable evidence).
struct BackgroundRefreshStatus {

    static let lastRunKey = "backgroundRefreshLastRun"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastRun: Date? {
        get { defaults.object(forKey: Self.lastRunKey) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Self.lastRunKey) }
    }
}
