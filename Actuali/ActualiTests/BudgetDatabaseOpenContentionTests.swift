import Foundation
import Testing
import GRDB
@testable import Actuali

/// Regression coverage for actios-tq4w, database-layer half: on a cold
/// headless Shortcut launch the store's budget load races the temporary
/// connection `accountsForIntent()` opens for entity resolution. Opening must
/// survive that race (wait for the lock, not throw SQLITE_BUSY), and a fully
/// migrated file must open without taking the write lock at all.
struct BudgetDatabaseOpenContentionTests {

    /// A file whose runnable migrations have all been applied by one
    /// `BudgetDatabase` open. The `transactions` table deliberately lacks the
    /// `schedule` column, so one schema-guarded migration stays unapplied
    /// forever — by design that must not count as pending write work.
    private func makeMigratedDatabaseFile() throws -> URL {
        let url = try makeSchemaOnlyFile()
        _ = try BudgetDatabase(path: url)
        return url
    }

    private func makeSchemaOnlyFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("contention-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    type TEXT,
                    offbudget INTEGER DEFAULT 0,
                    closed INTEGER DEFAULT 0,
                    sort_order REAL,
                    tombstone INTEGER DEFAULT 0
                );

                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY,
                    acct TEXT,
                    amount INTEGER,
                    tombstone INTEGER DEFAULT 0
                );
            """)
        }
        return url
    }

    /// The race itself: another connection holds an EXCLUSIVE lock (blocks
    /// readers and writers) while we open. With GRDB's default
    /// `.immediateError` busy mode this threw SQLITE_BUSY instantly; with
    /// `busyMode: .timeout` the open waits the ~300ms and succeeds.
    @Test func openWaitsForABusyDatabaseInsteadOfFailing() async throws {
        let url = try makeMigratedDatabaseFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let blocker = try DatabaseQueue(path: url.path)
        let lockHeld = DispatchSemaphore(value: 0)
        let thread = Thread {
            try? blocker.writeWithoutTransaction { db in
                try db.execute(sql: "BEGIN EXCLUSIVE")
                lockHeld.signal()
                Thread.sleep(forTimeInterval: 0.3)
                try db.execute(sql: "COMMIT")
            }
        }
        thread.start()
        lockHeld.wait()

        _ = try BudgetDatabase(path: url)
    }

    /// A write-protected file makes SQLite fall back to a read-only open, so
    /// any write — including a needless migration transaction — would throw.
    /// A fully migrated file must open cleanly anyway.
    @Test func fullyMigratedFileOpensWithoutWriting() throws {
        let url = try makeMigratedDatabaseFile()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: url.path)

        _ = try BudgetDatabase(path: url)
    }

    /// The precheck mirrors the write path's guards: pending on a fresh file,
    /// clear after one open — even though the guarded migration needing
    /// `transactions.schedule` remains unapplied. Each check opens its own
    /// connection: GRDB caches schema lookups per connection, so a queue that
    /// predates the migration run would not see the new tables.
    @Test func pendingWorkClearsAfterFirstOpen() throws {
        let url = try makeSchemaOnlyFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let freshFileNeedsWork = try DatabaseQueue(path: url.path)
            .read { try BudgetDatabase.pendingMigrationWork($0) }
        #expect(freshFileNeedsWork)

        _ = try BudgetDatabase(path: url)

        let migratedFileNeedsWork = try DatabaseQueue(path: url.path)
            .read { try BudgetDatabase.pendingMigrationWork($0) }
        #expect(!migratedFileNeedsWork)
    }
}
