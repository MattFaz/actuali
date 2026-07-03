import Foundation
import Testing
import GRDB
@testable import Actuali

/// Covers the 26.6.0/26.7.0 upstream migrations mirrored in BudgetDatabase:
/// tags.hidden, accounts.bank_sync_status, categories.cleanup_def,
/// custom_reports.show_trend_lines, cleanup_groups, transaction indexes —
/// plus the already-migrated-file guard and CRDT replay into new columns.
@MainActor
struct UpstreamSchemaMigrationTests {

    private func makeDatabasePath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
    }

    /// A budget file whose schema predates the mirrored migrations.
    private func makeLegacyFixture(_ path: URL) throws {
        let queue = try DatabaseQueue(path: path.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE tags (id TEXT PRIMARY KEY, tag TEXT, color TEXT, description TEXT, tombstone INTEGER DEFAULT 0);
                CREATE TABLE accounts (id TEXT PRIMARY KEY, name TEXT);
                CREATE TABLE categories (id TEXT PRIMARY KEY, name TEXT);
                CREATE TABLE schedules (id TEXT PRIMARY KEY, rule TEXT);
                CREATE TABLE transactions (id TEXT PRIMARY KEY, acct TEXT, amount INTEGER, schedule TEXT, tombstone INTEGER DEFAULT 0)
                """)
        }
    }

    private func columnNames(_ path: URL, table: String) throws -> Set<String> {
        let queue = try DatabaseQueue(path: path.path)
        return try queue.read { db in
            Set(try db.columns(in: table).map(\.name))
        }
    }

    @Test func addsUpstreamColumnsWhenTablesExist() throws {
        let path = makeDatabasePath()
        try makeLegacyFixture(path)

        _ = try BudgetDatabase(path: path)

        #expect(try columnNames(path, table: "tags").contains("hidden"))
        #expect(try columnNames(path, table: "accounts").contains("bank_sync_status"))
        #expect(try columnNames(path, table: "categories").contains("cleanup_def"))
        #expect(try columnNames(path, table: "custom_reports").contains("show_trend_lines"))
        #expect(try columnNames(path, table: "schedules").contains("custom_upcoming_length"))

        let queue = try DatabaseQueue(path: path.path)
        try queue.read { db in
            #expect(try db.tableExists("cleanup_groups"))
            let indexes = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'transactions'
                """)
            #expect(indexes.contains("idx_transactions_acct_tombstone"))
            #expect(indexes.contains("idx_transactions_schedule"))
        }
    }

    @Test func toleratesFileAlreadyMigratedByUpstreamClient() throws {
        // A freshly downloaded file from a 26.7.0 client already has the
        // columns; the ALTERs must be skipped (not fail with "duplicate
        // column") and recorded as applied.
        let path = makeDatabasePath()
        let queue = try DatabaseQueue(path: path.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE tags (id TEXT PRIMARY KEY, tag TEXT, hidden BOOLEAN DEFAULT 0);
                CREATE TABLE accounts (id TEXT PRIMARY KEY, name TEXT, bank_sync_status TEXT);
                CREATE TABLE categories (id TEXT PRIMARY KEY, name TEXT, cleanup_def TEXT);
                CREATE TABLE schedules (id TEXT PRIMARY KEY, custom_upcoming_length TEXT);
                CREATE TABLE transactions (id TEXT PRIMARY KEY, acct TEXT, amount INTEGER, schedule TEXT, tombstone INTEGER DEFAULT 0)
                """)
        }

        _ = try BudgetDatabase(path: path)

        try queue.read { db in
            let applied = Set(try Int64.fetchAll(db, sql: "SELECT id FROM __migrations__"))
            #expect(applied.contains(1769000000000))
            #expect(applied.contains(1780327681000))
            #expect(applied.contains(1780606215000))
        }
    }

    @Test func replaysStoredMessagesIntoNewlyAddedColumn() throws {
        // A CRDT message targeting tags.hidden arrived before the column
        // existed: applyMessages skipped it but it stayed in messages_crdt.
        // Running the migration must materialize the latest value per row.
        let path = makeDatabasePath()
        try makeLegacyFixture(path)
        let queue = try DatabaseQueue(path: path.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE messages_crdt (
                    id INTEGER PRIMARY KEY,
                    timestamp TEXT NOT NULL UNIQUE,
                    dataset TEXT NOT NULL,
                    row TEXT NOT NULL,
                    column TEXT NOT NULL,
                    value BLOB NOT NULL
                )
                """)
            try db.execute(sql: "INSERT INTO tags (id, tag) VALUES ('tag-1', 'work')")
            // Two messages for the same cell — the later one must win.
            try db.execute(sql: """
                INSERT INTO messages_crdt (timestamp, dataset, row, column, value) VALUES
                ('2026-06-01T00:00:00.000Z-0000-0000000000000001', 'tags', 'tag-1', 'hidden', 'N:1'),
                ('2026-06-02T00:00:00.000Z-0000-0000000000000001', 'tags', 'tag-1', 'hidden', 'N:0'),
                ('2026-06-03T00:00:00.000Z-0000-0000000000000001', 'tags', 'tag-2', 'hidden', 'N:1')
                """)
        }

        _ = try BudgetDatabase(path: path)

        try queue.read { db in
            let hidden = try Int.fetchOne(db, sql: "SELECT hidden FROM tags WHERE id = 'tag-1'")
            #expect(hidden == 0)
            // tag-2 didn't exist locally: replay creates the row like applyMessages would.
            let created = try Int.fetchOne(db, sql: "SELECT hidden FROM tags WHERE id = 'tag-2'")
            #expect(created == 1)
        }
    }

    @Test func migrationsAreIdempotentAcrossReopens() throws {
        let path = makeDatabasePath()
        try makeLegacyFixture(path)
        _ = try BudgetDatabase(path: path)
        _ = try BudgetDatabase(path: path)
    }
}
