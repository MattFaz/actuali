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

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    nonisolated var destinationName: String? {
        userDefaults.string(forKey: Self.nameKey)
    }

    nonisolated var isCustomDestinationConfigured: Bool {
        userDefaults.data(forKey: Self.bookmarkKey) != nil
    }

    /// Secures persistent access to the folder via a security-scoped bookmark.
    /// Runs synchronously so the bookmark is minted immediately while the picker's temporary access is active.
    nonisolated func saveDestination(from url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw BackupDestinationError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }

        // On iOS, empty options create a security-scoped bookmark from an open-in-place URL
        let bookmarkData = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        userDefaults.set(bookmarkData, forKey: Self.bookmarkKey)
        userDefaults.set(url.lastPathComponent, forKey: Self.nameKey)
        logger.info("Custom backup destination configured: \(url.lastPathComponent, privacy: .public)")
    }

    /// Clears the custom destination and returns to default local storage.
    nonisolated func clearDestination() {
        userDefaults.removeObject(forKey: Self.bookmarkKey)
        userDefaults.removeObject(forKey: Self.nameKey)
        logger.info("Custom backup destination reset to default")
    }

    /// Mirrors a local backup archive to the user-selected destination folder.
    /// ponytail: Mirroring runs fire-and-forget; if the destination is temporarily unavailable
    /// (e.g. offline iCloud Drive), local storage retains the master copy safely.
    func mirrorArchive(from sourceURL: URL, filename: String) async {
        guard let folderURL = resolveDestinationURL() else { return }
        guard folderURL.startAccessingSecurityScopedResource() else {
            logger.warning("Could not access security-scoped resource for custom backup destination")
            return
        }
        defer { folderURL.stopAccessingSecurityScopedResource() }

        // Must check existence *after* startAccessingSecurityScopedResource() is active
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            logger.warning("Custom destination folder no longer exists on disk")
            return
        }

        let targetURL = folderURL.appendingPathComponent(filename)
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?

        // options: [] allows creating a new file or replacing an existing file safely across file providers
        coordinator.coordinate(writingItemAt: targetURL, options: [], error: &coordinatorError) { writeURL in
            do {
                let data = try Data(contentsOf: sourceURL)
                try data.write(to: writeURL, options: .atomic)
                logger.info("Successfully mirrored backup archive \(filename, privacy: .public) to custom destination")
            } catch {
                logger.error("Failed to mirror backup archive: \(error.localizedDescription, privacy: .public)")
            }
        }

        if let coordinatorError {
            logger.error("File coordinator error while mirroring backup: \(coordinatorError.localizedDescription, privacy: .public)")
        }
    }

    /// Prunes a mirrored archive when retention removes it from local backups.
    func removeMirroredArchive(filename: String) async {
        guard let folderURL = resolveDestinationURL() else { return }
        guard folderURL.startAccessingSecurityScopedResource() else { return }
        defer { folderURL.stopAccessingSecurityScopedResource() }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }

        let targetURL = folderURL.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: targetURL.path) else { return }

        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?

        coordinator.coordinate(writingItemAt: targetURL, options: [], error: &coordinatorError) { writeURL in
            try? FileManager.default.removeItem(at: writeURL)
        }
    }

    /// Copies a list of existing archives to the destination (e.g. immediately after selecting a folder).
    func mirrorExistingBackups(urls: [URL]) async {
        for url in urls {
            await mirrorArchive(from: url, filename: url.lastPathComponent)
        }
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
