import Foundation
import GRDB
import Testing
@testable import Actuali

struct SyncClientTagTests {
    private func makeDatabase() throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE messages_crdt (
                id INTEGER PRIMARY KEY,
                timestamp TEXT NOT NULL UNIQUE,
                dataset TEXT NOT NULL,
                row TEXT NOT NULL,
                column TEXT NOT NULL,
                value BLOB NOT NULL
            );
            CREATE TABLE transactions (
                id TEXT PRIMARY KEY,
                acct TEXT,
                amount INTEGER,
                notes TEXT,
                date INTEGER,
                isParent INTEGER DEFAULT 0,
                isChild INTEGER DEFAULT 0,
                tombstone INTEGER DEFAULT 0
            );
            """)
        }
        return try (BudgetDatabase(path: tempURL), tempURL)
    }

    private func makeSyncClient(database: BudgetDatabase) async throws -> SyncClient {
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
        return syncClient
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test func createTagInsertsRowAndEmitsMessages() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)

        let tag = try await syncClient.createTag(name: "vacation", color: "#3b82f6", description: "Holiday")
        #expect(tag.tag == "vacation")

        let tagId = tag.id
        try await database.dbQueueForTesting.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM tags WHERE id = ?", arguments: [tagId])
            #expect(row != nil)
            #expect(row?["tag"] == "vacation")
            #expect(row?["color"] == "#3b82f6")

            let messages = try Row.fetchAll(db, sql: "SELECT * FROM messages_crdt WHERE dataset = 'tags' AND row = ?", arguments: [tagId])
            #expect(!messages.isEmpty)
        }
    }

    @Test func updateTagUpdatesRowAndEmitsMessages() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)

        var tag = try await syncClient.createTag(name: "travel")
        tag.color = "#00ff00"
        tag.description = "Updated"
        try await syncClient.updateTag(tag)

        let tagId = tag.id
        try await database.dbQueueForTesting.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM tags WHERE id = ?", arguments: [tagId])
            #expect(row?["color"] == "#00ff00")
            #expect(row?["description"] == "Updated")

            let colorMsg = try Row.fetchOne(db, sql: "SELECT * FROM messages_crdt WHERE dataset = 'tags' AND row = ? AND column = 'color'", arguments: [tagId])
            #expect(colorMsg != nil)
        }
    }

    @Test func deleteTagTombstonesAndEmitsMessage() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)

        let tag = try await syncClient.createTag(name: "temporary")
        try await syncClient.deleteTag(id: tag.id)

        let tagId = tag.id
        try await database.dbQueueForTesting.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT tombstone FROM tags WHERE id = ?", arguments: [tagId])
            #expect(row?["tombstone"] == 1)

            let tombstoneMsg = try Row.fetchOne(db, sql: "SELECT * FROM messages_crdt WHERE dataset = 'tags' AND row = ? AND column = 'tombstone'", arguments: [tagId])
            #expect(tombstoneMsg != nil)
        }
    }

    @Test func createTagRevivesTombstonedTagWithSameName() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)

        let original = try await syncClient.createTag(name: "coffee", color: "#ff0000")
        try await syncClient.deleteTag(id: original.id)
        let revived = try await syncClient.createTag(name: "coffee", color: "#00ff00")

        #expect(revived.id == original.id)
        let originalId = original.id
        try await database.dbQueueForTesting.read { db in
            // A second row would collide with the server's UNIQUE(tags.tag).
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags WHERE tag = 'coffee'")
            #expect(count == 1)
            let row = try Row.fetchOne(db, sql: "SELECT * FROM tags WHERE id = ?", arguments: [originalId])
            #expect(row?["tombstone"] == 0)
            #expect(row?["color"] == "#00ff00")
        }
    }

    @Test func renameTagOntoTombstonedNameThrows() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)

        let alpha = try await syncClient.createTag(name: "alpha")
        let beta = try await syncClient.createTag(name: "beta")
        try await syncClient.deleteTag(id: beta.id)

        await #expect(throws: SyncError.tagAlreadyExists) {
            try await syncClient.renameTag(id: alpha.id, oldName: "alpha", newName: "beta")
        }

        let alphaId = alpha.id
        try await database.dbQueueForTesting.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT tag FROM tags WHERE id = ?", arguments: [alphaId])
            #expect(row?["tag"] == "alpha")
        }
    }

    @Test func updateTagSkipsUnchangedFields() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }
        let syncClient = try await makeSyncClient(database: database)

        let tag = try await syncClient.createTag(name: "metrics")
        let tagId = tag.id

        let before = try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt WHERE dataset = 'tags' AND row = ?", arguments: [tagId]) ?? 0
        }
        try await syncClient.updateTag(tag) // no field changed
        let afterNoop = try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt WHERE dataset = 'tags' AND row = ?", arguments: [tagId]) ?? 0
        }
        #expect(afterNoop == before)

        var changed = tag
        changed.color = "#123456"
        try await syncClient.updateTag(changed)
        let afterChange = try await database.dbQueueForTesting.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt WHERE dataset = 'tags' AND row = ?", arguments: [tagId]) ?? 0
        }
        #expect(afterChange == before + 1)
    }

    @Test func renameTagUpdatesTagAndRewritesTransactions() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }

        try await database.dbQueueForTesting.write { db in
            try db.execute(sql: """
            INSERT INTO transactions (id, acct, amount, notes, date) VALUES
            ('tx-1', 'acct-1', -500, 'Office supplies #work', 20260101)
            """)
        }

        let syncClient = try await makeSyncClient(database: database)
        let tag = try await syncClient.createTag(name: "work")

        try await syncClient.renameTag(id: tag.id, oldName: "work", newName: "business")

        let tagId = tag.id
        try await database.dbQueueForTesting.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT tag FROM tags WHERE id = ?", arguments: [tagId])
            #expect(row?["tag"] == "business")

            let txNotes = try String.fetchOne(db, sql: "SELECT notes FROM transactions WHERE id = 'tx-1'")
            #expect(txNotes == "Office supplies #business")

            let txMsg = try Row.fetchOne(db, sql: "SELECT * FROM messages_crdt WHERE dataset = 'transactions' AND row = 'tx-1' AND column = 'notes'")
            #expect(txMsg != nil)
        }
    }
}
