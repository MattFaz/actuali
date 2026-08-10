import Foundation
import ZIPFoundation

enum BudgetFileError: LocalizedError {
    case invalidZipFile
    case missingDatabase
    case missingMetadata
    case extractionFailed(Error)
    case metadataParsingFailed

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

        // Open the ZIP archive
        let archive: Archive
        do {
            archive = try Archive(url: tempURL, accessMode: .read)
        } catch {
            throw BudgetFileError.invalidZipFile
        }

        // Find the required files
        guard let dbEntry = archive.first(where: { $0.path.hasSuffix("db.sqlite") }) else {
            throw BudgetFileError.missingDatabase
        }

        guard let metaEntry = archive.first(where: { $0.path.hasSuffix("metadata.json") }) else {
            throw BudgetFileError.missingMetadata
        }

        // Extract metadata first to get the budget ID
        var metadataData = Data()
        _ = try archive.extract(metaEntry) { data in
            metadataData.append(data)
        }

        guard let metadata = try? JSONDecoder().decode(BudgetMetadata.self, from: metadataData) else {
            throw BudgetFileError.metadataParsingFailed
        }

        // Update metadata with cloud info
        let updatedMetadata = BudgetMetadata(
            id: metadata.id,
            budgetName: metadata.budgetName,
            cloudFileId: fileId,
            groupId: groupId,
            resetClock: metadata.resetClock,
            lastUploaded: metadata.lastUploaded,
            encryptKeyId: metadata.encryptKeyId
        )

        // Create budget directory
        let budgetDir = budgetDirectory(for: metadata.id)
        try? fileManager.removeItem(at: budgetDir) // Remove existing if any
        try fileManager.createDirectory(at: budgetDir, withIntermediateDirectories: true)

        // Extract database
        let dbPath = databasePath(for: metadata.id)
        _ = try archive.extract(dbEntry, to: dbPath)

        // Write updated metadata
        let updatedMetadataData = try JSONEncoder().encode(updatedMetadata)
        try updatedMetadataData.write(to: metadataPath(for: metadata.id))

        return updatedMetadata
    }

    // MARK: - Delete

    func deleteBudget(_ budgetId: String) throws {
        let budgetDir = budgetDirectory(for: budgetId)
        try fileManager.removeItem(at: budgetDir)
    }
}
