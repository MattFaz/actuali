import BackgroundTasks
import Foundation

/// The Wallet delivery extension's record of its last FinanceKit wake (iOS
/// 26+), kept as a file in the app group container — same pattern as
/// `WidgetSnapshotStore` — so the app can show it in Settings.
///
/// The extension can't sync on its own: the budget, its sync state, and the
/// server credentials live in the app's container. On a Wallet change it asks
/// iOS to run the app's background refresh as soon as possible instead — iOS
/// only ever launches the host app to handle that request — and the refresh
/// already imports Wallet transactions (`BudgetStore.syncInBackground`), so
/// dedup, matching, and rules stay on the one code path that owns them.
struct WalletDelivery {
    /// The app's refresh task; must stay listed in
    /// BGTaskSchedulerPermittedIdentifiers.
    static let refreshTaskIdentifier = "com.mfazz.ActualiOS.refresh"

    struct Status: Codable, Equatable {
        /// When FinanceKit last woke the extension.
        var lastDelivery: Date?
        /// Why the last refresh request failed; nil after a success.
        var lastRequestError: String?
    }

    let fileURL: URL

    init(containerURL: URL) {
        fileURL = containerURL.appendingPathComponent("wallet-delivery.json")
    }

    /// nil when the app group container is unavailable — e.g. a provisioning
    /// profile without the app group capability.
    static func shared() -> WalletDelivery? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshotStore.appGroupID)
            .map(WalletDelivery.init(containerURL:))
    }

    func status() -> Status {
        (try? JSONDecoder().decode(Status.self, from: Data(contentsOf: fileURL))) ?? Status()
    }

    /// Handles one delivery: ask for the app's refresh with no start delay,
    /// then record the outcome. A submit replaces any pending request for the
    /// identifier, so a burst of deliveries coalesces into a single refresh.
    func requestRefresh(now: Date = Date(), submit: (BGTaskRequest) throws -> Void) {
        var status = Status(lastDelivery: now)
        do {
            try submit(BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier))
        } catch {
            status.lastRequestError = error.localizedDescription
        }
        try? JSONEncoder().encode(status).write(to: fileURL, options: .atomic)
    }
}
