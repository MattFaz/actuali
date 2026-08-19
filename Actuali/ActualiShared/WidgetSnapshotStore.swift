import Foundation

/// Reads and writes the category-balance snapshot in the app group container.
/// The app writes after every data refresh; the widget extension only reads.
struct WidgetSnapshotStore {
    /// Must match the app group in Actuali.entitlements and
    /// ActualiWidgets.entitlements.
    static let appGroupID = "group.com.mfazz.ActualiOS"

    let fileURL: URL

    init(containerURL: URL) {
        fileURL = containerURL.appendingPathComponent("widget-snapshot.json")
    }

    /// nil when the app group container is unavailable — e.g. a provisioning
    /// profile without the app group capability.
    static func standard() -> WidgetSnapshotStore? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            .map(WidgetSnapshotStore.init(containerURL:))
    }

    func write(_ snapshot: WidgetSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    /// Best-effort removal, used when the user disconnects so the widget
    /// doesn't keep showing the departed budget's balances.
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// nil when the snapshot is missing or unreadable.
    func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
}
