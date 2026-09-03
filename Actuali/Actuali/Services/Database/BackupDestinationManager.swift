import Foundation
import os

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "BackupDestination")

enum BackupDestinationError: LocalizedError {
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Permission was denied to access the selected folder."
        }
    }
}

/// Manages an optional user-selected destination folder (such as an iCloud Drive or local Files folder)
/// using iOS security-scoped bookmarks. Backups are mirrored to this folder while maintaining
/// master snapshots in local app storage.
actor BackupDestinationManager {
    static let shared = BackupDestinationManager()

    static let bookmarkKey = "actuali.backup.customDestinationBookmark"
    static let nameKey = "actuali.backup.customDestinationName"
    static let lastMirroredDateKey = "actuali.backup.lastMirroredDate"
    static let lastMirrorErrorKey = "actuali.backup.lastMirrorError"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var destinationName: String? {
        userDefaults.string(forKey: Self.nameKey)
    }

    var isCustomDestinationConfigured: Bool {
        userDefaults.data(forKey: Self.bookmarkKey) != nil
    }

    var lastMirroredDate: Date? {
        userDefaults.object(forKey: Self.lastMirroredDateKey) as? Date
    }

    var lastMirrorError: String? {
        userDefaults.string(forKey: Self.lastMirrorErrorKey)
    }

    /// Persists pre-minted bookmark data and folder name.
    func saveDestination(bookmarkData: Data, folderName: String) {
        userDefaults.set(bookmarkData, forKey: Self.bookmarkKey)
        userDefaults.set(folderName, forKey: Self.nameKey)
        userDefaults.removeObject(forKey: Self.lastMirrorErrorKey)
        logger.info("Custom backup destination configured: \(folderName, privacy: .public)")
    }

    /// Secures persistent access to the folder via a security-scoped bookmark.
    func saveDestination(from url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw BackupDestinationError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let bookmarkData = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        saveDestination(bookmarkData: bookmarkData, folderName: url.lastPathComponent)
    }

    /// Clears the custom destination and returns to default local storage.
    func clearDestination() {
        userDefaults.removeObject(forKey: Self.bookmarkKey)
        userDefaults.removeObject(forKey: Self.nameKey)
        userDefaults.removeObject(forKey: Self.lastMirroredDateKey)
        userDefaults.removeObject(forKey: Self.lastMirrorErrorKey)
        logger.info("Custom backup destination reset to default")
    }

    /// Mirrors a local backup archive to the user-selected destination folder under Actuali/<budgetId>/.
    /// ponytail: Mirroring runs fire-and-forget; if the destination is temporarily unavailable
    /// (e.g. offline iCloud Drive), local storage retains the master copy safely.
    func mirrorArchive(from sourceURL: URL, budgetId: String, filename: String) async {
        guard let folderURL = resolveDestinationURL() else { return }
        guard folderURL.startAccessingSecurityScopedResource() else {
            recordFailure("Could not access security-scoped destination")
            logger.warning("Could not access security-scoped resource for custom backup destination")
            return
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            recordFailure("Destination folder no longer exists")
            logger.warning("Custom destination folder no longer exists on disk")
            return
        }

        let budgetFolder = folderURL.appendingPathComponent("Actuali/\(budgetId)", isDirectory: true)
        try? FileManager.default.createDirectory(at: budgetFolder, withIntermediateDirectories: true)

        let targetURL = budgetFolder.appendingPathComponent(filename)
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var copyError: NSError?

        coordinator.coordinate(writingItemAt: targetURL, options: .forReplacing, error: &coordinatorError) { writeURL in
            do {
                try? FileManager.default.removeItem(at: writeURL)
                try FileManager.default.copyItem(at: sourceURL, to: writeURL)
                logger.info("Successfully mirrored backup archive \(filename, privacy: .public) to custom destination")
            } catch {
                copyError = error as NSError
                logger.error("Failed to mirror backup archive: \(error.localizedDescription, privacy: .public)")
            }
        }

        if let error = coordinatorError ?? copyError {
            recordFailure(error.localizedDescription)
        } else {
            recordSuccess()
        }
    }

    /// Prunes a mirrored archive when retention removes it from local backups.
    func removeMirroredArchive(budgetId: String, filename: String) async {
        guard let folderURL = resolveDestinationURL() else { return }
        guard folderURL.startAccessingSecurityScopedResource() else { return }
        defer { folderURL.stopAccessingSecurityScopedResource() }

        let targetURL = folderURL.appendingPathComponent("Actuali/\(budgetId)/\(filename)")
        guard FileManager.default.fileExists(atPath: targetURL.path) else { return }

        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?

        coordinator.coordinate(writingItemAt: targetURL, options: .forDeleting, error: &coordinatorError) { writeURL in
            try? FileManager.default.removeItem(at: writeURL)
        }
    }

    /// Copies a list of existing archives to the destination (e.g. immediately after selecting a folder).
    func mirrorExistingBackups(budgetId: String, urls: [URL]) async {
        for url in urls {
            await mirrorArchive(from: url, budgetId: budgetId, filename: url.lastPathComponent)
        }
    }

    private func recordSuccess() {
        userDefaults.set(Date(), forKey: Self.lastMirroredDateKey)
        userDefaults.removeObject(forKey: Self.lastMirrorErrorKey)
    }

    private func recordFailure(_ reason: String) {
        userDefaults.set(reason, forKey: Self.lastMirrorErrorKey)
    }

    private func resolveDestinationURL() -> URL? {
        guard let data = userDefaults.data(forKey: Self.bookmarkKey) else {
            return nil
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            logger.warning("Failed to resolve security-scoped bookmark for custom destination")
            return nil
        }

        if isStale {
            if url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }
                if let refreshed = try? url.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    userDefaults.set(refreshed, forKey: Self.bookmarkKey)
                    userDefaults.set(url.lastPathComponent, forKey: Self.nameKey)
                    logger.info("Refreshed stale security-scoped bookmark")
                }
            }
        }

        return url
    }
}
