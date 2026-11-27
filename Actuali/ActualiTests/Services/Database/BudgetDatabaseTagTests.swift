import Foundation
import GRDB
import Testing
@testable import Actuali

struct BudgetDatabaseTagTests {
    private func makeDatabase(seedSQL: String = "") async throws -> (BudgetDatabase, URL) {
        try await makeTestDatabase(
            TestSchema.tags, TestSchema.accounts, TestSchema.payees, TestSchema.payeeMapping,
            TestSchema.categories, TestSchema.categoryMapping, TestSchema.transactions, seedSQL
        )
    }

    @Test func insertsAndFetchesTags() async throws {
        let (database, path) = try await makeDatabase()
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
        let (database, path) = try await makeDatabase()
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
        let (database, path) = try await makeDatabase()
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
        let (database, path) = try await makeDatabase()
        defer { cleanup(path) }

        try database.insertTag(Tag(id: "t1", tag: "todelete"))
        try database.deleteTag(id: "t1")

        let fetched = try await database.fetchTags()
        #expect(fetched.isEmpty)
    }

    @Test func renamesTagAndRewritesTransactionNotes() async throws {
        let (database, path) = try await makeDatabase(seedSQL: """
        INSERT INTO tags (id, tag) VALUES ('t1', 'trip2025'), ('t2', 'cash');
        INSERT INTO transactions (id, acct, amount, notes, date) VALUES
        ('tx-1', 'acct-1', -1000, 'Hotel reservation #trip2025 in Rome', 20260101),
        ('tx-2', 'acct-1', -500, 'Flight #trip2025 #flight', 20260102),
        ('tx-3', 'acct-1', -200, 'Coffee without tag', 20260103),
        ('tx-4', 'acct-1', -300, 'Escaped ##trip2025 must not change', 20260104),
        ('tx-5', 'acct-1', -150, 'Atm withdrawal #cash', 20260105);
        """)
        defer { cleanup(path) }

        let modified = try database.renameTag(id: "t1", oldName: "trip2025", newName: "trip2026")
        #expect(modified.count == 2)

        let tags = try await database.fetchTags()
        #expect(tags.contains(where: { $0.tag == "trip2026" }))

        // Renaming to name containing $ must not crash or misinterpret regex capture groups
        let dollarModified = try database.renameTag(id: "t2", oldName: "cash", newName: "cash$back")
        #expect(dollarModified.count == 1)

        let queue = try DatabaseQueue(path: path.path)
        try await queue.read { db in
            let n1 = try String.fetchOne(db, sql: "SELECT notes FROM transactions WHERE id = 'tx-1'")
            #expect(n1 == "Hotel reservation #trip2026 in Rome")

            let n2 = try String.fetchOne(db, sql: "SELECT notes FROM transactions WHERE id = 'tx-2'")
            #expect(n2 == "Flight #trip2026 #flight")

            let n4 = try String.fetchOne(db, sql: "SELECT notes FROM transactions WHERE id = 'tx-4'")
            #expect(n4 == "Escaped ##trip2025 must not change")

            let n5 = try String.fetchOne(db, sql: "SELECT notes FROM transactions WHERE id = 'tx-5'")
            #expect(n5 == "Atm withdrawal #cash$back")
        }
    }

    @Test func discoversTagsFromTransactionNotes() async throws {
        let (database, path) = try await makeDatabase(seedSQL: """
        INSERT INTO tags (id, tag) VALUES ('t1', 'existing'), ('t-null', NULL);
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

    @Test func discoverTagsSkipsOnlyActiveNames() async throws {
        let (database, path) = try await makeDatabase(seedSQL: """
        INSERT INTO tags (id, tag) VALUES ('t1', 'existing');
        INSERT INTO tags (id, tag, tombstone) VALUES ('t2', 'archived', 1);
        INSERT INTO transactions (id, acct, amount, notes, date) VALUES
        ('tx-1', 'acct-1', -1000, 'Lunch #archived #fresh', 20260101);
        """)
        defer { cleanup(path) }

        let discovered = try await database.discoverTags()
        // Tombstoned names stay discoverable: importing reactivates the old
        // row instead of inserting a duplicate the server's UNIQUE would reject.
        #expect(discovered.contains("archived"))
        #expect(discovered.contains("fresh"))
        #expect(!discovered.contains("existing"))
    }

    @Test func aggregatesTagSummaries() async throws {
        let (database, path) = try await makeDatabase(seedSQL: """
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

        let travelSummary = summaries.first { $0.tag.tag == "travel" }
        #expect(travelSummary != nil)
        #expect(travelSummary?.transactionCount == 1)
        #expect(travelSummary?.totalSpent == 15000)
    }

    @Test func tagSummariesPreserveTagRowsAndTransactionPopulation() async throws {
        let (database, path) = try await makeDatabase(seedSQL: """
        INSERT INTO tags (id, tag, hidden) VALUES
        ('t-work', 'Work', 0), ('t-unused', 'unused', 0), ('t-hidden', 'hidden', 1);
        INSERT INTO transactions (id, acct, amount, notes, date, isParent, isChild, tombstone) VALUES
        ('tx-parent', 'acct-1', -700, '#WORK #work #hidden #unmanaged', 20260101, 1, 0, 0),
        ('tx-normal', 'acct-1', -300, '#work ##unused', 20260102, 0, 0, 0),
        ('tx-child', 'acct-1', -9000, '#work #hidden #unused', 20260101, 0, 1, 0),
        ('tx-deleted', 'acct-1', -8000, '#work #hidden #unused', 20260103, 0, 0, 1);
        """)
        defer { cleanup(path) }

        let summaries = try await database.fetchTagSummaries()
        #expect(summaries.map(\.id) == ["t-hidden", "t-unused", "t-work"])

        let hidden = try #require(summaries.first { $0.id == "t-hidden" })
        #expect(hidden.tag.hidden)
        #expect(hidden.transactionCount == 1)
        #expect(hidden.totalSpent == 700)
        #expect(hidden.netAmount == -700)

        let unused = try #require(summaries.first { $0.id == "t-unused" })
        #expect(unused.transactionCount == 0)
        #expect(unused.totalSpent == 0)
        #expect(unused.netAmount == 0)

        let work = try #require(summaries.first { $0.id == "t-work" })
        #expect(work.tag.tag == "Work")
        #expect(work.transactionCount == 2)
        #expect(work.totalSpent == 1000)
        #expect(work.netAmount == -1000)
    }

    @Test func fetchTransactionsTaggedWithFiltersCorrectly() async throws {
        let (database, path) = try await makeDatabase(seedSQL: """
        INSERT INTO accounts (id, name) VALUES ('acct-1', 'Checking');
        INSERT INTO transactions (id, acct, amount, notes, date) VALUES
        ('tx-1', 'acct-1', -4000, 'Dinner #food', 20260101),
        ('tx-2', 'acct-1', -6000, 'Groceries #food #healthy', 20260105),
        ('tx-3', 'acct-1', -15000, 'Train ticket #travel', 20260201);
        """)
        defer { cleanup(path) }

        let foodTxs = try await database.fetchTransactions(taggedWith: "food")
        #expect(foodTxs.count == 2)
        #expect(foodTxs.map(\.id) == ["tx-2", "tx-1"]) // newest first

        let travelTxs = try await database.fetchTransactions(taggedWith: "travel")
        #expect(travelTxs.count == 1)
        #expect(travelTxs.first?.id == "tx-3")

        let emptyTxs = try await database.fetchTransactions(taggedWith: "nonexistent")
        #expect(emptyTxs.isEmpty)
    }

    /// GH #785: a tag on one split line counts that line (not the whole
    /// parent); a tag on the parent counts the parent once, even when its
    /// lines repeat the tag.
    private static let splitSeed = """
    INSERT INTO accounts (id, name) VALUES ('acct-1', 'Checking');
    INSERT INTO payees (id, name) VALUES ('p-shop', 'Shop');
    INSERT INTO payee_mapping (id, targetId) VALUES ('p-shop', 'p-shop');
    INSERT INTO tags (id, tag) VALUES ('t-gift', 'gift'), ('t-trip', 'trip');
    INSERT INTO transactions (id, acct, amount, description, notes, date, isParent, isChild, parent_id, sort_order, tombstone) VALUES
    ('split-1', 'acct-1', -5000, 'p-shop', 'Weekly shop', 20260110, 1, 0, NULL, 1, 0),
    ('split-1-a', 'acct-1', -3000, NULL, NULL, 20260110, 0, 1, 'split-1', 2, 0),
    ('split-1-b', 'acct-1', -2000, NULL, 'Present #gift', 20260110, 0, 1, 'split-1', 3, 0),
    ('split-2', 'acct-1', -9000, 'p-shop', 'Holiday #trip', 20260111, 1, 0, NULL, 4, 0),
    ('split-2-a', 'acct-1', -6000, NULL, 'Hotel #trip', 20260111, 0, 1, 'split-2', 5, 0),
    ('split-2-b', 'acct-1', -3000, NULL, NULL, 20260111, 0, 1, 'split-2', 6, 0),
    ('dead', 'acct-1', -1000, 'p-shop', NULL, 20260112, 1, 0, NULL, 7, 1),
    ('dead-a', 'acct-1', -1000, NULL, '#gift', 20260112, 0, 1, 'dead', 8, 0);
    """

    @Test func fetchTransactionsTaggedWithIncludesTaggedSplitLines() async throws {
        let (database, path) = try await makeDatabase(seedSQL: Self.splitSeed)
        defer { cleanup(path) }

        let gift = try await database.fetchTransactions(taggedWith: "gift")
        #expect(gift.map(\.id) == ["split-1-b"])
        #expect(gift.first?.amount == -2000)
        #expect(gift.first?.parentId == "split-1")
        #expect(gift.first?.payeeName == "Shop")

        let trip = try await database.fetchTransactions(taggedWith: "trip")
        #expect(trip.map(\.id) == ["split-2"])
    }

    @Test func tagSummariesCountTaggedSplitLines() async throws {
        let (database, path) = try await makeDatabase(seedSQL: Self.splitSeed)
        defer { cleanup(path) }

        let summaries = try await database.fetchTagSummaries()
        let gift = try #require(summaries.first { $0.id == "t-gift" })
        #expect(gift.transactionCount == 1)
        #expect(gift.totalSpent == 2000)
        #expect(gift.netAmount == -2000)

        let trip = try #require(summaries.first { $0.id == "t-trip" })
        #expect(trip.transactionCount == 1)
        #expect(trip.totalSpent == 9000)
    }
}
