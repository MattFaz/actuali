import Combine
import Foundation
import os

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "PendingImportStore")

/// Persists pending transaction imports as a JSON file in the app's documents
/// directory. Observable so the toolbar badge and review sheet react to changes.
@MainActor
final class PendingImportStore: ObservableObject {

    enum StoreError: LocalizedError, Equatable {
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let message):
                return String(localized: "Failed to save pending imports: \(message)")
            }
        }
    }

    static let shared = PendingImportStore()

    @Published private(set) var imports: [PendingImport] = []

    var count: Int { imports.count }

    func visibleImports() -> [PendingImport] {
        imports
    }

    private let fileURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.fileURL = docs.appendingPathComponent("pending_imports.json")
        load()
    }

    #if DEBUG
    /// Test-only initializer that reads from a custom path.
    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }
    #endif

    func add(_ item: PendingImport) throws {
        var updated = imports
        updated.insert(item, at: 0)
        try save(updated)
        imports = updated
        logger.info("Queued pending import \(item.id, privacy: .public)")
    }

    func remove(id: UUID) throws {
        let updated = imports.filter { $0.id != id }
        try save(updated)
        imports = updated
    }

    func removeAll() throws {
        try save([])
        imports = []
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            imports = try JSONDecoder().decode([PendingImport].self, from: data)
        } catch {
            logger.error("Failed to load pending imports: \(error.localizedDescription, privacy: .public)")
            do {
                let backupURL = try preserveCorruptFile()
                imports = []
                try? save([])
                logger.error("Recovered pending imports as an empty queue; corrupt data preserved at \(backupURL.path, privacy: .public)")
            } catch {
                logger.error("Could not preserve corrupt pending imports; original file was left untouched: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func preserveCorruptFile() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmssSSS"
        let backupURL = fileURL.deletingPathExtension()
            .appendingPathExtension("corrupt-\(formatter.string(from: Date()))-\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: fileURL, to: backupURL)
        return backupURL
    }

    private func save(_ imports: [PendingImport]) throws {
        do {
            let data = try JSONEncoder().encode(imports)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save pending imports: \(error.localizedDescription, privacy: .public)")
            throw StoreError.saveFailed(error.localizedDescription)
        }
    }
}
