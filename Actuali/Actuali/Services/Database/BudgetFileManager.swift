import Foundation
import ZIPFoundation

enum BudgetFileError: LocalizedError {
    case invalidZipFile
    case missingDatabase
    case missingMetadata
    case extractionFailed(Error)
    case metadataParsingFailed
    case unsafeArchive(String)

    var errorDescription: String? {
        switch self {
        case .invalidZipFile:
            return "The downloaded file is not a valid ZIP archive"
        case .missingDatabase:
            return "The budget file is missing the database"
        case .missingMetadata:
            return "The budget file is missing metadata"
        case .extractionFailed(let error):
            return "Failed to extract budget file: \(error.localizedDescription)"
        case .metadataParsingFailed:
            return "Failed to parse budget metadata"
        case .unsafeArchive(let error):
            return "The archive failed a safety check: \(error)"
        }
    }
}

struct BudgetMetadata: Codable {
    let id: String
    let budgetName: String?
    let cloudFileId: String?
    let groupId: String?
    let resetClock: Bool?
    let lastUploaded: String?
    let encryptKeyId: String?
}

class BudgetFileManager {
    static let shared = BudgetFileManager()

    private let fileManager = FileManager.default

    /// Non-nil only in tests: roots budgetsDirectory somewhere disposable.
    private let rootDirectoryOverride: URL?

    private init() {
        rootDirectoryOverride = nil
    }

    #if DEBUG
    /// Test-only: a file manager rooted at a custom directory so destructive
    /// operations (logout's full wipe) can run isolated from the shared
    /// Budgets directory while suites execute in parallel.
    init(rootDirectoryForTesting: URL) {
        rootDirectoryOverride = rootDirectoryForTesting
    }
    #endif

    // MARK: - Directories

    var budgetsDirectory: URL {
        let base = rootDirectoryOverride
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let budgetsDir = base.appendingPathComponent("Budgets", isDirectory: true)

        if !fileManager.fileExists(atPath: budgetsDir.path) {
            try? fileManager.createDirectory(at: budgetsDir, withIntermediateDirectories: true)
        }

        return budgetsDir
    }

    func budgetDirectory(for budgetId: String) -> URL {
        budgetsDirectory.appendingPathComponent(budgetId, isDirectory: true)
    }

    func databasePath(for budgetId: String) -> URL {
        budgetDirectory(for: budgetId).appendingPathComponent("db.sqlite")
    }

    func metadataPath(for budgetId: String) -> URL {
        budgetDirectory(for: budgetId).appendingPathComponent("metadata.json")
    }
    
    // MARK: - Backup Paths
    
    /// Directory holding this budget's local backup archives, created on first use.
    func backupsDirectory(for budgetId: String) -> URL {
        let dir = budgetDirectory(for: budgetId).appendingPathComponent("backups", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    func backupPath(for budgetId: String, name: String) -> URL {
        backupsDirectory(for: budgetId).appendingPathComponent(name)
    }
    
    /// The baseline that will be reverted too if there is ever a failure in backing up.
    func latestDatabasePath(for budgetId: String) -> URL {
        budgetDirectory(for: budgetId).appendingPathComponent("db.latest.sqlite")
    }
    
    func latestMetadataPath(for budgetId: String) -> URL {
        budgetDirectory(for: budgetId).appendingPathComponent("metadata.latest.json")
    }
    
    // MARK: - Backup Naming
    
    /// Archive names match upstream's yyyy-MM-dd_HH-mm-ss.zip.
    /// The device timezone is deliberate: "today"  means the user's today.
    static let backupNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()
    
    static func backupArchiveName(for date: Date) -> String {
        backupNameFormatter.string(from: date) + ".zip"
    }

    static func backupTempName(now: Date) -> String {
        "db.\(Int(now.timeIntervalSince1970 * 1000)).sqlite.tmp"
    }
    
    // MARK: - Backup Archives
    
    /// Creates a backup archive with EXACTLY the two root entries the import
    /// path looks for, so Actuali-made archives round-trip through
    /// `importBudget` and open in Actual desktop (upstream zips the same two
    /// names, backups.ts:145-148).
    func makeBudgetArchive(dbURL: URL, metadataURL: URL, to destinationURL: URL) throws {
        // Same-second collision between a manual and an automatic backup:
        // overwrite, matching upstream (the contents are equivalent).
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        let archive = try Archive(url: destinationURL, accessMode: .create)
        try archive.addEntry(with: "db.sqlite", fileURL: dbURL, compressionMethod: .deflate)
        try archive.addEntry(with: "metadata.json", fileURL: metadataURL, compressionMethod: .deflate)
    }

    /// Ported from upstream's safeUnzip caps (util/zip.ts:9): fflate there —
    /// and ZIPFoundation here — do no validation themselves, so guard against
    /// zip-slip and decompression bombs before extracting anything.
    private static let maxArchiveBytes = 500 * 1024 * 1024

    /// util/zip.ts:20-35 — reject NUL, backslash, drive-letter prefix,
    /// absolute paths, and `..` as a path *segment* (segment comparison, not
    /// a substring match: "a..b/x" is legal, "a/../x" is not).
    private func assertSafeEntryName(_ name: String) throws {
        let hasTraversal = name
            .split(separator: "/", omittingEmptySubsequences: false)
            .contains("..")
        if name.contains("\0")
            || name.contains("\\")
            || name.range(of: #"^[a-zA-Z]:"#, options: .regularExpression) != nil
            || name.hasPrefix("/")
            || hasTraversal {
            throw BudgetFileError.unsafeArchive("unsafe entry name: \(name)")
        }
    }

    struct ExtractedBudget {
        /// Temporary location of the extracted database. The caller owns it
        /// and must delete it (or move it into place).
        let databaseURL: URL
        let metadataData: Data
        let metadata: BudgetMetadata
    }

    /// Opens a budget archive, validates it (entry names, size caps, duplicates), and extracts db.sqlite to a temp file.
    /// Shared by server import and backup restore.
    func extractBudgetArchive(at archiveURL: URL) throws -> ExtractedBudget {
        if let size = (try? fileManager.attributesOfItem(atPath: archiveURL.path))?[.size] as? Int,
           size > Self.maxArchiveBytes {
            throw BudgetFileError.unsafeArchive("archive exceeds \(Self.maxArchiveBytes) bytes")
        }

        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            throw BudgetFileError.invalidZipFile
        }

        var seen = Set<String>()
        var totalUncompressed = 0
        for entry in archive {
            try assertSafeEntryName(entry.path)
            let entrySize = Int(entry.uncompressedSize)
            if entrySize > Self.maxArchiveBytes {
                throw BudgetFileError.unsafeArchive("entry \(entry.path) exceeds \(Self.maxArchiveBytes) bytes")
            }
            totalUncompressed += entrySize
            if totalUncompressed > Self.maxArchiveBytes {
                throw BudgetFileError.unsafeArchive("total uncompressed size exceeds \(Self.maxArchiveBytes) bytes")
            }
            if !seen.insert(entry.path.lowercased()).inserted {
                throw BudgetFileError.unsafeArchive("duplicate entry: \(entry.path)")
            }
        }

        guard let dbEntry = archive.first(where: { $0.path.hasSuffix("db.sqlite") }) else {
            throw BudgetFileError.missingDatabase
        }
        guard let metaEntry = archive.first(where: { $0.path.hasSuffix("metadata.json") }) else {
            throw BudgetFileError.missingMetadata
        }

        var metadataData = Data()
        _ = try archive.extract(metaEntry) { metadataData.append($0) }
        guard let metadata = try? JSONDecoder().decode(BudgetMetadata.self, from: metadataData) else {
            throw BudgetFileError.metadataParsingFailed
        }

        let tempDbURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sqlite")
        _ = try archive.extract(dbEntry, to: tempDbURL)

        return ExtractedBudget(databaseURL: tempDbURL, metadataData: metadataData, metadata: metadata)
    }

    // MARK: - Budget Management

    func listLocalBudgets() -> [BudgetMetadata] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: budgetsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }

        return contents.compactMap { url -> BudgetMetadata? in
            let metadataURL = url.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metadataURL),
                  let metadata = try? JSONDecoder().decode(BudgetMetadata.self, from: data) else {
                return nil
            }
            return metadata
        }
    }

    func budgetExists(_ budgetId: String) -> Bool {
        let dbPath = databasePath(for: budgetId)
        return fileManager.fileExists(atPath: dbPath.path)
    }

    // MARK: - Import

    func importBudget(from zipData: Data, fileId: String, groupId: String?) async throws -> BudgetMetadata {
        // Create a temporary file for the ZIP
        let tempURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try zipData.write(to: tempURL)

        defer {
            try? fileManager.removeItem(at: tempURL)
        }
        
        let extracted = try extractBudgetArchive(at: tempURL)
        defer {
            try? fileManager.removeItem(at: extracted.databaseURL)
        }

        // Update metadata with cloud info
        let updatedMetadata = BudgetMetadata(
            id: extracted.metadata.id,
            budgetName: extracted.metadata.budgetName,
            cloudFileId: fileId,
            groupId: groupId,
            resetClock: extracted.metadata.resetClock,
            lastUploaded: extracted.metadata.lastUploaded,
            encryptKeyId: extracted.metadata.encryptKeyId
        )

        // Replace only the live files — deleting the whole directory here used to be harmless,
        // but it would now silently destroy backups/ on every re-download. A fresh download does,
        // however, supersede any revert baseline.
        let budgetDir = budgetDirectory(for: extracted.metadata.id)
        try fileManager.createDirectory(at: budgetDir, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: latestDatabasePath(for: extracted.metadata.id))
        try? fileManager.removeItem(at: latestMetadataPath(for: extracted.metadata.id))

        let dbPath = databasePath(for: extracted.metadata.id)
        for suffix in ["-wal", "-shm"] {
            try? fileManager.removeItem(at: URL(fileURLWithPath: dbPath.path + suffix))
        }
        try? fileManager.removeItem(at: dbPath)
        try fileManager.moveItem(at: extracted.databaseURL, to: dbPath)

        // Write updated metadata
        let updatedMetadataData = try JSONEncoder().encode(updatedMetadata)
        try updatedMetadataData.write(to: metadataPath(for: extracted.metadata.id))

        return updatedMetadata
    }

    // MARK: - Delete

    func deleteBudget(_ budgetId: String) throws {
        let budgetDir = budgetDirectory(for: budgetId)
        try fileManager.removeItem(at: budgetDir)
    }
}

extension BudgetMetadata {
    /// The metadata to persist after restoring this (archived) metadata over a
    /// live budget. Sync-group fields are nulled: upstream nulls them only
    /// transiently before its re-upload registers a fresh server group
    /// (backups.ts:220-224, cloud-storage.ts:347), but Actuali has no upload
    /// path, so a restored fork must stay detached until the user re-downloads
    /// (docs/backup-planning/implementation-plan.md §1, D1). Identity fields
    /// come from the live metadata when present — the directory's live file is
    /// the source of truth for which cloud file this is.
    func restoredOver(_ live: BudgetMetadata?) -> BudgetMetadata {
        BudgetMetadata(
            id: id,
            budgetName: budgetName,
            cloudFileId: live?.cloudFileId ?? cloudFileId,
            groupId: nil,
            resetClock: resetClock,
            lastUploaded: nil,
            encryptKeyId: live?.encryptKeyId ?? encryptKeyId
        )
    }
}
