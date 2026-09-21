import Foundation
import GRDB
import Testing
@testable import Actuali

struct BudgetDatabaseTagTests {
    private func makeDatabase(seedSQL: String = "") throws -> (BudgetDatabase, URL) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: tempURL.path)
        try queue.write { db in
            try db.execute(sql: """
            CREATE TABLE tags (
                id TEXT PRIMARY KEY,
                tag TEXT,
                color TEXT,
                description TEXT,
                hidden BOOLEAN DEFAULT 0,
                tombstone INTEGER DEFAULT 0
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
            if !seedSQL.isEmpty {
                try db.execute(sql: seedSQL)
            }
        }
        return try (BudgetDatabase(path: tempURL), tempURL)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test func insertsAndFetchesTags() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }

        let tag1 = Tag(id: "tag-1", tag: "vacation", color: "#3b82f6", description: "Holiday trip")
        let tag2 = Tag(id: "tag-2", tag: "groceries", color: "#ef4444")
        try database.insertTag(tag1)
        try database.insertTag(tag2)

        let fetched = try await database.fetchTags()
        #expect(fetched.count == 2)
        #expect(fetched[0].tag == "groceries") // sorted alphabetically
        #expect(fetched[1].tag == "vacation")
        #expect(fetched[1].color == "#3b82f6")
        #expect(fetched[1].description == "Holiday trip")
    }

    @Test func fetchesTagsExcludingHidden() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }

        try database.insertTag(Tag(id: "t1", tag: "visible"))
        try database.insertTag(Tag(id: "t2", tag: "hidden", hidden: true))

        let all = try await database.fetchTags(includeHidden: true)
        #expect(all.count == 2)

        let visibleOnly = try await database.fetchTags(includeHidden: false)
        #expect(visibleOnly.count == 1)
        #expect(visibleOnly[0].tag == "visible")
    }

    @Test func updatesTagMetadata() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }

        let tag = Tag(id: "t1", tag: "travel", color: "#ffffff")
        try database.insertTag(tag)

        var updated = tag
        updated.color = "#000000"
        updated.description = "Updated desc"
        updated.hidden = true
        try database.updateTag(updated)

        let fetched = try await database.fetchTags()
        #expect(fetched.count == 1)
        #expect(fetched[0].color == "#000000")
        #expect(fetched[0].description == "Updated desc")
        #expect(fetched[0].hidden == true)
    }

    @Test func deleteTagSetsTombstone() async throws {
        let (database, path) = try makeDatabase()
        defer { cleanup(path) }

        try database.insertTag(Tag(id: "t1", tag: "todelete"))
        try database.deleteTag(id: "t1")

        let fetched = try await database.fetchTags()
        #expect(fetched.isEmpty)
    }

    @Test func renamesTagAndRewritesTransactionNotes() async throws {
        let (database, path) = try makeDatabase(seedSQL: """
        INSERT INTO tags (id, tag) VALUES ('t1', 'trip2025');
        INSERT INTO transactions (id, acct, amount, notes, date) VALUES
        ('tx-1', 'acct-1', -1000, 'Hotel reservation #trip2025 in Rome', 20260101),
        ('tx-2', 'acct-1', -500, 'Flight #trip2025 #flight', 20260102),
        ('tx-3', 'acct-1', -200, 'Coffee without tag', 20260103),
        ('tx-4', 'acct-1', -300, 'Escaped ##trip2025 must not change', 20260104);
        """)
        defer { cleanup(path) }

        let modified = try database.renameTag(id: "t1", oldName: "trip2025", newName: "trip2026")
        #expect(modified.count == 2)

        let tags = try await database.fetchTags()
        #expect(tags.first?.tag == "trip2026")

        let queue = try DatabaseQueue(path: path.path)
        try await queue.read { db in
            let n1 = try String.fetchOne(db, sql: "SELECT notes FROM transactions WHERE id = 'tx-1'")
            #expect(n1 == "Hotel reservation #trip2026 in Rome")

            let n2 = try String.fetchOne(db, sql: "SELECT notes FROM transactions WHERE id = 'tx-2'")
            #expect(n2 == "Flight #trip2026 #flight")

            let n4 = try String.fetchOne(db, sql: "SELECT notes FROM transactions WHERE id = 'tx-4'")
            #expect(n4 == "Escaped ##trip2025 must not change")
        }
    }

    @Test func discoversTagsFromTransactionNotes() async throws {
        let (database, path) = try makeDatabase(seedSQL: """
        INSERT INTO tags (id, tag) VALUES ('t1', 'existing');
        INSERT INTO transactions (id, acct, amount, notes, date) VALUES
        ('tx-1', 'acct-1', -1000, 'Lunch #food #work', 20260101),
        ('tx-2', 'acct-1', -500, 'Taxi #work #travel', 20260102),
        ('tx-3', 'acct-1', -200, 'Already known #existing', 20260103);
        """)
        defer { cleanup(path) }

        let discovered = try await database.discoverTags()
        #expect(discovered.contains("food"))
        #expect(discovered.contains("work"))
        #expect(discovered.contains("travel"))
        #expect(!discovered.contains("existing"))
    }

    @Test func aggregatesTagSummaries() async throws {
        let (database, path) = try makeDatabase(seedSQL: """
        INSERT INTO tags (id, tag) VALUES ('t1', 'food'), ('t2', 'travel');
        INSERT INTO transactions (id, acct, amount, notes, date) VALUES
        ('tx-1', 'acct-1', -4000, 'Dinner #food', 20260101),
        ('tx-2', 'acct-1', -6000, 'Groceries #food', 20260105),
        ('tx-3', 'acct-1', 1000, 'Refund #food', 20260106),
        ('tx-4', 'acct-1', -15000, 'Train ticket #travel', 20260201);
        """)
        defer { cleanup(path) }

        let summaries = try await database.fetchTagSummaries()
        #expect(summaries.count == 2)

        let foodSummary = summaries.first { $0.tag.tag == "food" }
        #expect(foodSummary != nil)
        #expect(foodSummary?.transactionCount == 3)
        #expect(foodSummary?.totalSpent == 10000) // 4000 + 6000
        #expect(foodSummary?.netAmount == -9000) // -4000 - 6000 + 1000
        #expect(foodSummary?.earliestDate == DayDate(yyyymmdd: 20_260_101))
        #expect(foodSummary?.latestDate == DayDate(yyyymmdd: 20_260_106))

        let travelSummary = summaries.first { $0.tag.tag == "travel" }
        #expect(travelSummary != nil)
        #expect(travelSummary?.transactionCount == 1)
        #expect(travelSummary?.totalSpent == 15000)
    }
}
