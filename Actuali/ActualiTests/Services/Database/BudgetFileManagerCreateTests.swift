import Foundation
import Testing
@testable import Actuali

/// Budget creation file plumbing (GH #387): new budget directories mirror
/// upstream's createBudget (id shape from idFromBudgetName, metadata from
/// getDefaultPrefs, db.sqlite copied from a template), and the upload archive
/// mirrors exportBuffer's resetClock stamp.
struct BudgetFileManagerCreateTests {
    private func makeManager() -> (BudgetFileManager, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (BudgetFileManager(rootDirectoryForTesting: root), root)
    }

    private func writeTemplate(in root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("template.sqlite")
        try Data("not-really-sqlite".utf8).write(to: url)
        return url
    }

    /// Upstream idFromBudgetName: every space or non-alphanumeric flattened to
    /// "-", then "-" plus 7 characters of a UUID (hex, since a UUID's first
    /// dash sits at index 8).
    @Test func budgetIdMatchesUpstreamShape() {
        let id = BudgetFileManager.budgetId(fromName: "My Finances")
        #expect(id.range(of: "^My-Finances-[0-9a-f]{7}$", options: .regularExpression) != nil)

        let punctuated = BudgetFileManager.budgetId(fromName: "Büdget (2026)!")
        #expect(punctuated.range(of: "^B-dget--2026---[0-9a-f]{7}$", options: .regularExpression) != nil)
    }

    @Test func createBudgetWritesTemplateCopyAndDefaultMetadata() throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let templateURL = try writeTemplate(in: root)

        let metadata = try manager.createBudget(named: "Fresh Start", templateURL: templateURL)

        #expect(metadata.budgetName == "Fresh Start")
        #expect(metadata.id.hasPrefix("Fresh-Start-"))
        let dbData = try Data(contentsOf: manager.databasePath(for: metadata.id))
        #expect(dbData == Data("not-really-sqlite".utf8))

        // metadata.json is upstream's getDefaultPrefs shape: id and budgetName
        // only — no sync-group keys until the upload registers the file.
        let metadataData = try Data(contentsOf: manager.metadataPath(for: metadata.id))
        let json = try #require(
            try JSONSerialization.jsonObject(with: metadataData) as? [String: Any]
        )
        #expect(Set(json.keys) == ["id", "budgetName"])
        #expect(manager.listLocalBudgets().contains { $0.id == metadata.id })
    }

    @Test func createBudgetRemovesPartialDirectoryAfterFileError() throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: (any Error).self) {
            try manager.createBudget(
                named: "Broken", templateURL: root.appendingPathComponent("missing.sqlite")
            )
        }
        #expect(manager.listLocalBudgets().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(
            at: manager.budgetsDirectory, includingPropertiesForKeys: nil
        ).isEmpty)
    }

    @Test func headlessDownloadCannotReplaceExistingBudgetFiles() async throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceDB = root.appendingPathComponent("source.sqlite")
        let sourceMetadata = root.appendingPathComponent("source.json")
        let archive = root.appendingPathComponent("remote.zip")
        try Data("remote snapshot".utf8).write(to: sourceDB)
        try Data(#"{"id":"shared-local-id","budgetName":"Remote"}"#.utf8)
            .write(to: sourceMetadata)
        try manager.makeBudgetArchive(
            dbURL: sourceDB, metadataURL: sourceMetadata, to: archive
        )

        let localDirectory = manager.budgetDirectory(for: "shared-local-id")
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
        let originalDatabase = Data("local unsynced changes".utf8)
        let originalMetadata = Data(#"{"id":"shared-local-id","budgetName":"Local"}"#.utf8)
        try originalDatabase.write(to: manager.databasePath(for: "shared-local-id"))
        try originalMetadata.write(to: manager.metadataPath(for: "shared-local-id"))

        let archiveData = try Data(contentsOf: archive)
        await #expect(throws: BudgetFileError.self) {
            try await manager.importBudget(
                from: archiveData, fileId: "remote-cloud-file",
                groupId: "remote-group", replaceExisting: false
            )
        }
        // Even explicit UI downloads must not overwrite a different cloud file
        // or a local-only budget just because the archive IDs collide.
        await #expect(throws: BudgetFileError.self) {
            try await manager.importBudget(
                from: archiveData, fileId: "remote-cloud-file",
                groupId: "remote-group", replaceExisting: true
            )
        }
        #expect(try Data(contentsOf: manager.databasePath(for: "shared-local-id")) == originalDatabase)
        #expect(try Data(contentsOf: manager.metadataPath(for: "shared-local-id")) == originalMetadata)

        // A genuinely absent local budget remains downloadable.
        try FileManager.default.removeItem(at: localDirectory)
        let imported = try await manager.importBudget(
            from: archiveData, fileId: "remote-cloud-file",
            groupId: "remote-group", encryptionKeyId: "persisted-key-id",
            replaceExisting: false
        )
        #expect(imported.cloudFileId == "remote-cloud-file")
        #expect(imported.encryptKeyId == "persisted-key-id")
        let reloaded = try JSONDecoder().decode(
            BudgetMetadata.self, from: Data(contentsOf: manager.metadataPath(for: imported.id))
        )
        #expect(reloaded.encryptKeyId == "persisted-key-id")
        #expect(try Data(contentsOf: manager.databasePath(for: "shared-local-id"))
            == Data("remote snapshot".utf8))
    }

    @Test func uploadArchiveStampsResetClockAndPreservesUnknownKeys() throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = manager.budgetDirectory(for: "b1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("db-bytes".utf8).write(to: manager.databasePath(for: "b1"))
        try Data(#"{"id":"b1","budgetName":"B","futureKey":"kept"}"#.utf8)
            .write(to: manager.metadataPath(for: "b1"))

        let zipData = try manager.makeUploadArchive(for: "b1")

        let zipURL = root.appendingPathComponent("upload.zip")
        try zipData.write(to: zipURL)
        let extracted = try manager.extractBudgetArchive(at: zipURL)
        defer { try? FileManager.default.removeItem(at: extracted.databaseURL) }

        #expect(try Data(contentsOf: extracted.databaseURL) == Data("db-bytes".utf8))
        let archivedJson = try #require(
            try JSONSerialization.jsonObject(with: extracted.metadataData) as? [String: Any]
        )
        // The archived copy tells downloaders to mint a fresh clock node
        // (upstream exportBuffer), and keys this app doesn't model survive.
        #expect(archivedJson["resetClock"] as? Bool == true)
        #expect(archivedJson["futureKey"] as? String == "kept")

        // The live metadata is untouched.
        let liveJson = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: manager.metadataPath(for: "b1"))
            ) as? [String: Any]
        )
        #expect(liveJson["resetClock"] == nil)
    }
}
