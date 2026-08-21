import Combine
import Foundation
import os

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "PendingImportStore")

/// Persists pending transaction imports as a JSON file in the app's documents
/// directory. Observable so the toolbar badge and review sheet react to changes.
@MainActor
final class PendingImportStore: ObservableObject {

    static let shared = PendingImportStore()

    @Published private(set) var imports: [PendingImport] = []

    var count: Int { imports.count }

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

    func add(_ item: PendingImport) {
        imports.insert(item, at: 0)
        save()
        logger.info("Queued pending import \(item.id, privacy: .public)")
    }

    func remove(id: UUID) {
        imports.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        imports.removeAll()
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            imports = try JSONDecoder().decode([PendingImport].self, from: data)
        } catch {
            logger.error("Failed to load pending imports: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(imports)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save pending imports: \(error.localizedDescription, privacy: .public)")
        }
    }
}
