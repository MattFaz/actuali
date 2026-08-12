import Foundation
import GRDB
import Testing
import ZIPFoundation

@testable import Actuali

struct BudgetArchiveWriterTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFixtureBudget(in dir: URL, id: String) throws -> (dbURL: URL, metadataURL: URL) {
        let dbURL = dir.appendingPathComponent("db.sqlite")
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        try dbQueue.write { db in
            try db.execute(sql: "CREATE TABLE t (id TEXT PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO t VALUES ('a')")
        }

        let metadata = BudgetMetadata(
            id: id, budgetName: "Fixture", cloudFileId: nil, groupId: nil,
            resetClock: nil, lastUploaded: nil, encryptKeyId: nil
        )
        let metadataURL = dir.appendingPathComponent("metadata.json")
        try JSONEncoder().encode(metadata).write(to: metadataURL)
        return (dbURL, metadataURL)
    }

    // The interop guarantee: an Actuali-made archive round-trips through the
    // same import path a server download uses.
    @Test func archiveRoundTripsThroughImportBudget() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = BudgetFileManager(
            rootDirectoryForTesting: dir.appendingPathComponent("root", isDirectory: true)
        )

        let fixture = try writeFixtureBudget(in: dir, id: "roundtrip")
        let archiveURL = dir.appendingPathComponent("backup.zip")
        try manager.makeBudgetArchive(
            dbURL: fixture.dbURL, metadataURL: fixture.metadataURL, to: archiveURL
        )

        let imported = try await manager.importBudget(
            from: Data(contentsOf: archiveURL), fileId: "file-1", groupId: "group-1"
        )
        #expect(imported.id == "roundtrip")
        #expect(imported.cloudFileId == "file-1")
        #expect(imported.groupId == "group-1")

        let importedQueue = try DatabaseQueue(path: manager.databasePath(for: "roundtrip").path)
        let count = try await importedQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM t") }
        #expect(count == 1)
    }

    @Test func extractionRejectsTraversalEntryNames() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = BudgetFileManager(
            rootDirectoryForTesting: dir.appendingPathComponent("root", isDirectory: true)
        )

        let archiveURL = dir.appendingPathComponent("evil.zip")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        let payload = Data("boom".utf8)
        try archive.addEntry(
            with: "../evil.txt", type: .file, uncompressedSize: Int64(payload.count)
        ) { position, size in
            payload.subdata(in: Int(position)..<(Int(position) + size))
        }

        #expect(throws: BudgetFileError.self) {
            _ = try manager.extractBudgetArchive(at: archiveURL)
        }
    }

    @Test func extractionRejectsCaseInsensitiveDuplicates() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = BudgetFileManager(
            rootDirectoryForTesting: dir.appendingPathComponent("root", isDirectory: true)
        )

        let archiveURL = dir.appendingPathComponent("dupes.zip")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        let payload = Data("x".utf8)
        for name in ["db.sqlite", "DB.SQLITE"] {
            try archive.addEntry(
                with: name, type: .file, uncompressedSize: Int64(payload.count)
            ) { position, size in
                payload.subdata(in: Int(position)..<(Int(position) + size))
            }
        }

        #expect(throws: BudgetFileError.self) {
            _ = try manager.extractBudgetArchive(at: archiveURL)
        }
    }

    @Test func extractionRequiresBothEntries() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = BudgetFileManager(
            rootDirectoryForTesting: dir.appendingPathComponent("root", isDirectory: true)
        )

        let fixture = try writeFixtureBudget(in: dir, id: "solo")
        let archiveURL = dir.appendingPathComponent("dbonly.zip")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try archive.addEntry(with: "db.sqlite", fileURL: fixture.dbURL, compressionMethod: .deflate)

        #expect(throws: BudgetFileError.self) {
            _ = try manager.extractBudgetArchive(at: archiveURL)
        }
    }
}
