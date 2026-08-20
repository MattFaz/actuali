import Foundation
import GRDB
import os

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "BudgetDatabase")

// MARK: - Database Records (matching Actual's schema)

struct AccountRecord: Codable, FetchableRecord, TableRecord {
    static let databaseTableName = "accounts"

    let id: String
    let name: String?
    let type: String?
    let offbudget: Int?
    let closed: Int?
    let tombstone: Int?
    let sortOrder: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case offbudget
        case closed
        case tombstone
        case sortOrder = "sort_order"
    }
}

struct TransactionRecord: Codable, FetchableRecord, TableRecord {
    static let databaseTableName = "transactions"

    let id: String
    let isParent: Int?
    let isChild: Int?
    let acct: String?
    let category: String?
    let amount: Int?
    let description: String?
    let notes: String?
    let date: Int?
    let importedDescription: String?
    let transferredId: String?
    let cleared: Int?
    let reconciled: Int?
    let sortOrder: Double?
    let tombstone: Int?
    let parentId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case isParent
        case isChild
        case acct
        case category
        case amount
        case description
        case notes
        case date
        case importedDescription = "imported_description"
        case transferredId = "transferred_id"
        case cleared
        case reconciled
        case sortOrder = "sort_order"
        case tombstone
        case parentId = "parent_id"
    }
}

struct CategoryRecord: Codable, FetchableRecord, TableRecord {
    static let databaseTableName = "categories"

    let id: String
    let name: String?
    let isIncome: Int?
    let catGroup: String?
    let sortOrder: Double?
    let hidden: Int?
    let tombstone: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case isIncome = "is_income"
        case catGroup = "cat_group"
        case sortOrder = "sort_order"
        case hidden
        case tombstone
    }
}

struct CategoryGroupRecord: Codable, FetchableRecord, TableRecord {
    static let databaseTableName = "category_groups"

    let id: String
    let name: String?
    let isIncome: Int?
    let sortOrder: Double?
    let hidden: Int?
    let tombstone: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case isIncome = "is_income"
        case sortOrder = "sort_order"
        case hidden
        case tombstone
    }
}

struct PayeeRecord: Codable, FetchableRecord, TableRecord {
    static let databaseTableName = "payees"

    let id: String
    let name: String?
    let transferAcct: String?
    let tombstone: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case transferAcct = "transfer_acct"
        case tombstone
    }
}

struct PayeeMappingRecord: Codable, FetchableRecord, TableRecord {
    static let databaseTableName = "payee_mapping"

    let id: String
    let targetId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case targetId
    }
}

// MARK: - Budget Database

/// SQLite access for a single budget file (GRDB).
///
/// Methods are deliberately split between async and sync, and new methods
/// must pick the side that matches their caller:
///
/// - **Async methods** are UI-facing reads called from `BudgetStore`
///   (`@MainActor`). They run via `await dbQueue.read { ... }` so the query
///   executes off the caller's executor and never blocks the main thread.
///   Any new read that feeds published UI state belongs here.
///
/// - **Sync (throwing, non-async) methods** are `SyncClient`'s transactional
///   paths: single-transaction shapes (insert/apply/filter messages, clock
///   persistence) that the actor must complete without a suspension point.
///   In particular, `saveClock` must stay synchronous — `SyncClient` relies
///   on the clock read → assignment → save sequence running without
///   interleaving (see the reentrancy comment in `SyncClient.swift`). Making
///   one of these async introduces an `await`, which opens an actor
///   reentrancy window mid-transaction. Any new write that participates in
///   CRDT message application or clock state belongs here.
class BudgetDatabase {
    private let dbQueue: DatabaseQueue

    init(path: URL) throws {
        // Concurrent opens of the same file are expected: on a cold headless
        // Shortcut launch, the store's budget load races the temporary
        // connection `accountsForIntent()` opens for entity resolution. GRDB's
        // default busy mode (.immediateError) turns that brief overlap into a
        // spurious SQLITE_BUSY, which BudgetStore then treats as a failed
        // load. Wait for the lock instead — contention here is milliseconds.
        var config = Configuration()
        config.busyMode = .timeout(5)
        dbQueue = try DatabaseQueue(path: path.path, configuration: config)
        try runPendingMigrations()
    }

    // MARK: - Schema Migrations

    // Upstream Actual schema migrations we mirror. These only run if the source
    // table exists and every `requiresColumns` column is present (otherwise
    // they stay unapplied and are retried on a later open). When `addsColumn`
    // is already present — a freshly downloaded file migrated by an up-to-date
    // client — the migration is recorded as applied without executing, since
    // the ALTER would fail with "duplicate column". CREATE migrations always
    // run (CREATE TABLE IF NOT EXISTS handles idempotency).
    private static let upstreamSchemaMigrations: [(
        id: Int64, table: String, addsColumn: String?, requiresColumns: [String], sql: String
    )] = [
        // Second half of upstream 1765518577215 (multiple dashboards, see
        // createTableMigrations): widgets gain a page pointer. Files that
        // predate the migration get the column here so page-assignment CRDT
        // messages can land instead of being skipped.
        (1765518577216, "dashboard", "dashboard_page_id", [],
         "ALTER TABLE dashboard ADD COLUMN dashboard_page_id TEXT"),
        (1769000000000, "schedules", "custom_upcoming_length", [],
         "ALTER TABLE schedules ADD COLUMN custom_upcoming_length TEXT DEFAULT NULL"),
        // Upstream 1778510362740 also creates cleanup_groups (see createTableMigrations).
        (1778510362741, "categories", "cleanup_def", [],
         "ALTER TABLE categories ADD COLUMN cleanup_def TEXT DEFAULT NULL"),
        (1780099200000, "custom_reports", "show_trend_lines", [],
         "ALTER TABLE custom_reports ADD COLUMN show_trend_lines INTEGER DEFAULT 0"),
        (1780327681000, "tags", "hidden", [],
         "ALTER TABLE tags ADD COLUMN hidden BOOLEAN DEFAULT 0"),
        // Locally minted id mirroring upstream's schedules feature, which
        // predates every migration in this list: old snapshots can lack
        // transactions.schedule, but the transaction fetches now select it
        // (posted scheduled transactions link back to their schedule), so
        // backfill the column here. Must precede the index migration below so
        // both apply in one open.
        (1780606214999, "transactions", "schedule", [],
         "ALTER TABLE transactions ADD COLUMN schedule TEXT"),
        (1780606215000, "accounts", "bank_sync_status", [],
         "ALTER TABLE accounts ADD COLUMN bank_sync_status TEXT"),
        // Upstream ships both indexes as one migration (1780606215001); split
        // here so each waits for its own columns.
        (1780606215001, "transactions", nil, ["acct", "tombstone"],
         "CREATE INDEX IF NOT EXISTS idx_transactions_acct_tombstone ON transactions(acct, tombstone)"),
        (1780606215002, "transactions", nil, ["schedule"],
         "CREATE INDEX IF NOT EXISTS idx_transactions_schedule ON transactions(schedule)")
    ]

    // Tables added upstream after the original budget file was created. These run
    // unconditionally so CRDT messages targeting these tables have somewhere to land.
    private static let createTableMigrations: [(id: Int64, sql: String)] = [
        // Upstream 1765518577215 (multiple dashboards): pages table. Only the
        // schema half of upstream's migration — upstream also mints a default
        // "Main" page and moves widgets onto it, but that half generates no
        // CRDT messages and forks a fresh page id on every client that runs
        // it, so doing it here would add yet another divergent page. Pageless
        // widgets still render via the nil-page fallback (ReportsTabView's
        // resolvePageId → fetchWidgets(pageId: nil)).
        (1765518577215, """
            CREATE TABLE IF NOT EXISTS dashboard_pages (
                id TEXT PRIMARY KEY,
                name TEXT,
                tombstone INTEGER DEFAULT 0
            )
            """),
        // Upstream 1768872504000 (Actual 26.4.0): payee locations. Same SQL
        // as upstream's migration, so we reuse its id — a file already
        // migrated by a modern client skips this cleanly.
        (1768872504000, """
            CREATE TABLE IF NOT EXISTS payee_locations (
                id TEXT PRIMARY KEY,
                payee_id TEXT,
                latitude REAL,
                longitude REAL,
                created_at INTEGER,
                tombstone INTEGER DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_payee_locations_payee_id ON payee_locations (payee_id);
            CREATE INDEX IF NOT EXISTS idx_payee_locations_tombstone_payee_created ON payee_locations (tombstone, payee_id, created_at);
            CREATE INDEX IF NOT EXISTS idx_payee_locations_geo_tombstone ON payee_locations (tombstone, latitude, longitude)
            """),
        (1770000000001, """
            CREATE TABLE IF NOT EXISTS dashboard (
                id TEXT PRIMARY KEY,
                type TEXT,
                dashboard_page_id TEXT,
                x INTEGER DEFAULT 0,
                y INTEGER DEFAULT 0,
                width INTEGER DEFAULT 4,
                height INTEGER DEFAULT 2,
                meta TEXT,
                tombstone INTEGER NOT NULL DEFAULT 0
            )
        """),
        (1770000000002, """
            CREATE TABLE IF NOT EXISTS custom_reports (
                id TEXT PRIMARY KEY,
                name TEXT,
                start_date TEXT,
                end_date TEXT,
                date_range TEXT,
                mode TEXT,
                group_by TEXT,
                interval TEXT,
                balance_type TEXT,
                show_empty INTEGER DEFAULT 0,
                show_offbudget INTEGER DEFAULT 0,
                show_hidden INTEGER DEFAULT 0,
                show_uncategorized INTEGER DEFAULT 0,
                selected_categories TEXT,
                graph_type TEXT,
                conditions TEXT,
                conditions_op TEXT,
                metadata TEXT,
                tombstone INTEGER NOT NULL DEFAULT 0
            )
        """),
        (1778510362740, """
            CREATE TABLE IF NOT EXISTS cleanup_groups (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                tombstone INTEGER DEFAULT 0
            )
        """)
    ]
    
    /// Migration ids Actuali mints itself, no upstream migration file has
    /// them (split halves of upstream migrations, plus defensive backfills).
    /// Actual's import validates a file's __migrations__ rows against its
    /// migrations directory and rejects unknown ids (loot-core
    /// migrations.ts, checkDatabaseValidity), so backups strip these before
    /// archiving. Any id added to upstreamSchemaMigrations or
    /// createTableMigrations that doesn't exist in upstream's migrations/
    /// directory MUST also be listed here.
    static let actualiOnlyMigrationIds: [Int64] = [
        1765518577216, // ALTER half of upstream 1765518577215 (dashboard_page_id)
        1770000000001, // defensive CREATE dashboard
        1770000000002, // defensive CREATE custom_reports
        1778510362741, // ALTER half of upstream 1778510362740 (cleanup_def)
        1780606214999, // locally minted transactions.schedule backfill
        1780606215002, // second half of upstream index migration 1780606215001
    ]

    /// Whether `runPendingMigrations()` would perform any write. Mirrors the
    /// guards of the write path below so a fully migrated file opens without
    /// ever taking the write lock — opening is a hot, concurrent path (see
    /// `init`). Migrations whose guards aren't satisfied yet (source table or
    /// required columns missing) are not work: the write path would skip them
    /// too. Internal for tests.
    static func pendingMigrationWork(_ db: Database) throws -> Bool {
        guard try db.tableExists("__migrations__") else { return true }
        let appliedIds = Set(try Int64.fetchAll(db, sql: "SELECT id FROM __migrations__"))

        if createTableMigrations.contains(where: { !appliedIds.contains($0.id) }) {
            return true
        }
        for migration in upstreamSchemaMigrations where !appliedIds.contains(migration.id) {
            guard try db.tableExists(migration.table) else { continue }
            let existing = Set(try db.columns(in: migration.table).map(\.name))
            guard migration.requiresColumns.allSatisfy(existing.contains) else { continue }
            // Runnable (ALTER/CREATE INDEX), or the column already exists and
            // needs its bookkeeping row — either way the write path has work.
            return true
        }
        return false
    }

    private func runPendingMigrations() throws {
        guard try dbQueue.read({ try Self.pendingMigrationWork($0) }) else { return }
        try dbQueue.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS __migrations__ (id INTEGER PRIMARY KEY)")

            let appliedIds = Set(try Int64.fetchAll(db, sql: "SELECT id FROM __migrations__"))

            // CREATE migrations: run unconditionally (CREATE IF NOT EXISTS handles existing tables)
            for migration in Self.createTableMigrations where !appliedIds.contains(migration.id) {
                logger.info("Applying create-table migration \(migration.id, privacy: .public)")
                try db.execute(sql: migration.sql)
                try db.execute(
                    sql: "INSERT INTO __migrations__ (id) VALUES (?)",
                    arguments: [migration.id]
                )
            }

            // Schema-guarded migrations: skip if the source table doesn't exist
            var addedColumns: [(table: String, column: String)] = []
            for migration in Self.upstreamSchemaMigrations where !appliedIds.contains(migration.id) {
                guard try db.tableExists(migration.table) else { continue }
                let existing = Set(try db.columns(in: migration.table).map(\.name))
                guard migration.requiresColumns.allSatisfy(existing.contains) else { continue }
                if let column = migration.addsColumn, existing.contains(column) {
                    // Downloaded file was already migrated by an up-to-date
                    // client; ALTER would fail with "duplicate column".
                    try db.execute(
                        sql: "INSERT INTO __migrations__ (id) VALUES (?)",
                        arguments: [migration.id]
                    )
                    continue
                }
                logger.info("Applying upstream schema migration \(migration.id, privacy: .public)")
                try db.execute(sql: migration.sql)
                try db.execute(
                    sql: "INSERT INTO __migrations__ (id) VALUES (?)",
                    arguments: [migration.id]
                )
                if let column = migration.addsColumn {
                    addedColumns.append((migration.table, column))
                }
            }

            try Self.replayStoredMessages(db, into: addedColumns)
        }
    }

    /// CRDT messages targeting columns the local schema didn't have yet are
    /// skipped by applyMessages but kept in messages_crdt. Once a migration
    /// adds such a column, materialize the latest stored value per row so the
    /// data isn't missing until the next remote edit. HLC timestamp strings
    /// order lexicographically (filterNewMessages already relies on this), so
    /// MAX(timestamp) per row is the winning message.
    private static func replayStoredMessages(
        _ db: Database,
        into addedColumns: [(table: String, column: String)]
    ) throws {
        guard !addedColumns.isEmpty, try db.tableExists("messages_crdt") else { return }

        for (table, column) in addedColumns {
            let rows = try Row.fetchAll(db, sql: """
                SELECT row, value, MAX(timestamp) AS ts
                FROM messages_crdt
                WHERE dataset = ? AND column = ?
                GROUP BY row
                """, arguments: [table, column])
            guard !rows.isEmpty else { continue }

            logger.info("Replaying \(rows.count, privacy: .public) stored message(s) into \(table, privacy: .public).\(column, privacy: .public)")
            let quotedTable = quotedIdentifier(table)
            let quotedColumn = quotedIdentifier(column)
            for row in rows {
                guard let rowId: String = row["row"], let value: String = row["value"] else { continue }
                try upsertValue(
                    db, table: quotedTable, column: quotedColumn,
                    rowId: rowId, value: CRDTValue.deserialize(value)
                )
            }
        }
    }
    
    // MARK: - Backup Support

    /// Writes a consistent single-file snapshot of the live database, regardless of journal mode.
    func snapshotDatabase(to url: URL) async throws {
        try await dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
        }
    }

    // MARK: - Accounts

    func fetchAccounts() async throws -> [Account] {
        try await dbQueue.read { db in
            let records = try AccountRecord
                .filter(Column("tombstone") == 0 || Column("tombstone") == nil)
                .order(Column("sort_order").asc)
                .fetchAll(db)

            // Balances in one grouped query instead of a SUM per account (N+1).
            // Split transactions are stored as a parent row carrying the full
            // amount plus child rows carrying each portion, so the children sum
            // to the parent. We must exclude parents (isParent = 0) or every
            // split would be counted twice — matching Actual's own aggregate
            // semantics and fetchTransactionsForReports(). We must also exclude
            // children whose parent is tombstoned or missing: deleting a split
            // tombstones the parent but leaves the child rows with tombstone =
            // 0, so a per-row tombstone check alone would still count those
            // orphans, and upstream's alive view joins the parent row itself,
            // so a child whose parent row never materialized doesn't count
            // either. Transfer legs still count; accounts with no transactions
            // get 0.
            //
            // date IS NOT NULL mirrors upstream v_transactions_internal: a
            // CRDT update for a row whose insert messages are gone (e.g.
            // after a sync reset) materializes a half-applied row with no
            // date, which official clients never show or count (GH #275).
            let balanceRows = try Row.fetchAll(db, sql: """
                SELECT t.acct AS acct, COALESCE(SUM(t.amount), 0) AS balance
                FROM transactions t
                LEFT JOIN transactions p ON p.id = t.parent_id
                WHERE t.acct IS NOT NULL
                  AND t.date IS NOT NULL
                  AND (t.tombstone = 0 OR t.tombstone IS NULL)
                  AND \(Self.aliveChildPredicate(parent: "p"))
                  AND (t.isParent = 0 OR t.isParent IS NULL)
                GROUP BY t.acct
                """)
            var balances: [String: Int] = [:]
            for row in balanceRows {
                guard let acct: String = row["acct"] else { continue }
                balances[acct] = row["balance"] ?? 0
            }

            return records.map { record in
                Account(
                    id: record.id,
                    name: record.name ?? "Unknown",
                    type: AccountType(rawValue: record.type ?? "checking") ?? .checking,
                    offBudget: record.offbudget == 1,
                    closed: record.closed == 1,
                    sortOrder: Int(record.sortOrder ?? 0),
                    balance: balances[record.id] ?? 0
                )
            }
        }
    }
    
    /// A month's income and spending for the accounts tab's summary group
    /// (GH #256), on the same footing as the budget tab's Income and Spent.
    struct AccountsMonthSummary: Equatable {
        var incomeCents = 0
        /// Spending sign-flipped to read as money out, so a normal month is
        /// positive. Net activity, like the budget tab's Spent (GH #212):
        /// refunds offset spending, and a month whose refunds outweigh it
        /// goes negative — the same figure the budget tab shows, so both
        /// tabs stay in step.
        var expenseCents = 0

        /// What the month kept: income less what actually went out. A net
        /// refund makes `expenseCents` negative and so adds here, which is
        /// the cash that stayed.
        var netCents: Int { incomeCents - expenseCents }
    }

    /// Income and expenses for one "yyyy-MM" month.
    ///
    /// Same scope as the budget month's income/spent so the two tabs agree
    /// (GH #256): categorised transactions in on-budget accounts only, with
    /// hidden categories and hidden groups left out the way the budget tab's
    /// Income/Spent totals leave them out. Income is the income categories'
    /// activity, expenses the rest — so an off-budget account's spending
    /// doesn't land in either, and transfers need no special-casing (an
    /// on-budget↔on-budget transfer carries no category; a categorised leg
    /// into an off-budget account is spending, as upstream counts it).
    /// Split parents are excluded and their children counted, matching the
    /// budget's spent query. Deleted accounts are excluded as well: upstream
    /// tombstones an account's transactions along with it, so a live
    /// transaction left on a tombstoned account is a sync-race orphan the
    /// all-accounts balance above the card doesn't count either.
    func fetchAccountsMonthSummary(month: String) async throws -> AccountsMonthSummary {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT
                    COALESCE(SUM(CASE WHEN c.is_income = 1 THEN t.amount ELSE 0 END), 0) AS income,
                    COALESCE(SUM(CASE WHEN c.is_income = 1 THEN 0 ELSE -t.amount END), 0) AS expense
                FROM transactions t
                LEFT JOIN category_mapping cm ON cm.id = t.category
                JOIN categories c ON c.id = COALESCE(cm.transferId, t.category)
                JOIN category_groups g ON g.id = c.cat_group
                JOIN accounts a ON a.id = t.acct
                LEFT JOIN transactions par ON par.id = t.parent_id
                WHERE (t.tombstone = 0 OR t.tombstone IS NULL)
                  AND (t.isParent = 0 OR t.isParent IS NULL)
                  AND \(Self.aliveChildPredicate(parent: "par"))
                  AND (c.tombstone = 0 OR c.tombstone IS NULL)
                  AND (c.hidden = 0 OR c.hidden IS NULL)
                  AND (g.tombstone = 0 OR g.tombstone IS NULL)
                  AND (g.hidden = 0 OR g.hidden IS NULL)
                  AND a.offbudget = 0
                  AND (a.tombstone = 0 OR a.tombstone IS NULL)
                  AND (t.date / 100) = ?
                """, arguments: [Self.monthStringToInt(month)]) else {
                return AccountsMonthSummary()
            }
            let income: Int = row["income"] ?? 0
            let expense: Int = row["expense"] ?? 0
            return AccountsMonthSummary(incomeCents: income, expenseCents: expense)
        }
    }

    // MARK: - Transactions

    /// Alive-child filter for every query that counts split children:
    /// mirrors upstream v_transactions_internal_alive, which joins the
    /// parent row of every is_child = 1 row and requires it to exist with
    /// tombstone = 0, so children of tombstoned or never-materialized
    /// parents count nowhere. `parent` is the joined parent row's alias.
    private static func aliveChildPredicate(parent: String) -> String {
        "(t.isChild = 0 OR t.isChild IS NULL OR (\(parent).id IS NOT NULL AND (\(parent).tombstone = 0 OR \(parent).tombstone IS NULL)))"
    }

    /// SELECT + display-name joins + liveness filter shared by the
    /// creation-detection and single-id transaction queries. The list query
    /// (fetchTransactions) carries additional split-aware joins of its own.
    private static let transactionSelect = """
        SELECT
            t.id, t.isParent, t.isChild, t.acct, t.category, t.amount,
            t.description, t.notes, t.date, t.imported_description,
            t.schedule,
            t.transferred_id, t.cleared, t.reconciled, t.sort_order,
            t.tombstone, t.parent_id,
            COALESCE(pa.name, p.name) as payee_name,
            c.name as category_name,
            p.transfer_acct as transfer_acct
        FROM transactions t
        LEFT JOIN payee_mapping pm ON pm.id = t.description
        LEFT JOIN payees p ON p.id = pm.targetId
        -- Transfer payees carry no name; their display name is the
        -- linked account's name (matches Actual's v_payees view).
        LEFT JOIN accounts pa ON pa.id = p.transfer_acct
            AND (pa.tombstone = 0 OR pa.tombstone IS NULL)
        LEFT JOIN category_mapping cm ON cm.id = t.category
        LEFT JOIN categories c ON c.id = COALESCE(cm.transferId, t.category)
        WHERE (t.tombstone = 0 OR t.tombstone IS NULL)
          AND (t.isChild = 0 OR t.isChild IS NULL)
          AND t.date IS NOT NULL
          AND t.acct IS NOT NULL
        """

    private static func mapTransaction(_ row: Row) -> Transaction {
        Transaction(
            id: row["id"],
            accountId: row["acct"] ?? "",
            date: row["date"] ?? 0,
            amount: row["amount"] ?? 0,
            payeeId: row["description"],
            payeeName: row["payee_name"],
            categoryId: row["category"],
            categoryName: row["category_name"],
            notes: row["notes"],
            cleared: row["cleared"] == 1,
            reconciled: row["reconciled"] == 1,
            transferId: row["transferred_id"],
            isParent: row["isParent"] == 1,
            parentId: row["parent_id"],
            tombstone: row["tombstone"] == 1,
            sortOrder: row["sort_order"],
            importedPayee: row["imported_description"],
            schedule: row["schedule"],
            transferAcct: row["transfer_acct"]
        )
    }

    /// Single live transaction by id, with display names. Nil when missing or
    /// tombstoned (notification tap-through falls back to the list).
    func fetchTransaction(id: String) async throws -> Transaction? {
        try await dbQueue.read { db in
            try Row.fetchOne(db, sql: Self.transactionSelect + " AND t.id = ?", arguments: [id])
                .map(Self.mapTransaction)
        }
    }

    /// Rows per page in the transaction lists. One page is the default for
    /// `fetchTransactions`, and TransactionPager treats a shorter page as
    /// the end of the result set.
    static let transactionPageSize = 500

    /// Page through transactions newest-first, optionally scoped to one
    /// account and/or filtered by a free-text search. `search` applies the
    /// TransactionSearchMatcher semantics (payee, category, notes, and
    /// progressive amount matching) in SQL so it covers full history, not
    /// just the loaded page. `unclearedOnly` drops cleared rows (which
    /// includes reconciled ones — locking requires cleared first) in SQL for
    /// the same reason: pages stay full-sized and cover full history.
    func fetchTransactions(
        accountId: String? = nil,
        limit: Int = BudgetDatabase.transactionPageSize,
        offset: Int = 0,
        search: String? = nil,
        unclearedOnly: Bool = false
    ) async throws -> [Transaction] {
        try await dbQueue.read { db in
            // The list's display payee: own payee first (transfer payees show
            // the linked account's name), else the split children's agreed
            // payee. Referenced by both SELECT and the search filter, which
            // must match what the row visibly shows.
            let payeeNameSQL = "COALESCE(pa.name, p.name, cpa.name, cp.name)"
            var sql = """
                SELECT
                    t.id, t.isParent, t.isChild, t.acct, t.category, t.amount,
                    t.description, t.notes, t.date, t.imported_description,
                    t.schedule,
                    t.transferred_id, t.cleared, t.reconciled, t.sort_order,
                    t.tombstone, t.parent_id,
                    \(payeeNameSQL) as payee_name,
                    c.name as category_name,
                    p.transfer_acct as transfer_acct
                FROM transactions t
                LEFT JOIN payee_mapping pm ON pm.id = t.description
                LEFT JOIN payees p ON p.id = pm.targetId
                -- Transfer payees carry no name; their display name is the
                -- linked account's name (matches Actual's v_payees view).
                LEFT JOIN accounts pa ON pa.id = p.transfer_acct
                    AND (pa.tombstone = 0 OR pa.tombstone IS NULL)
                -- Split parents may carry no payee of their own (payees can
                -- live on the children, GH #47). When the live children agree
                -- on one payee, display it; mixed payees resolve NULL and the
                -- UI labels the row "Split".
                LEFT JOIN (
                    SELECT ct.parent_id AS parent_id,
                           CASE WHEN COUNT(DISTINCT ct.description) = 1
                                THEN MIN(ct.description) END AS payee
                    FROM transactions ct
                    WHERE ct.isChild = 1
                      AND (ct.tombstone = 0 OR ct.tombstone IS NULL)
                      AND ct.description IS NOT NULL
                    GROUP BY ct.parent_id
                ) child_payee ON t.isParent = 1 AND child_payee.parent_id = t.id
                LEFT JOIN payee_mapping cpm ON cpm.id = child_payee.payee
                LEFT JOIN payees cp ON cp.id = cpm.targetId
                LEFT JOIN accounts cpa ON cpa.id = cp.transfer_acct
                    AND (cpa.tombstone = 0 OR cpa.tombstone IS NULL)
                LEFT JOIN category_mapping cm ON cm.id = t.category
                LEFT JOIN categories c ON c.id = COALESCE(cm.transferId, t.category)
                WHERE (t.tombstone = 0 OR t.tombstone IS NULL)
                  AND (t.isChild = 0 OR t.isChild IS NULL)
                  AND t.date IS NOT NULL
                  AND t.acct IS NOT NULL
                """

            var arguments: [(any DatabaseValueConvertible)?] = []

            if let accountId {
                sql += " AND t.acct = ?"
                arguments.append(accountId)
            }

            if unclearedOnly {
                sql += " AND (t.cleared = 0 OR t.cleared IS NULL)"
            }

            if let search {
                let matcher = TransactionSearchMatcher(search)
                if !matcher.text.isEmpty {
                    let escaped = matcher.text
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "%", with: "\\%")
                        .replacingOccurrences(of: "_", with: "\\_")
                    let pattern = "%\(escaped)%"
                    var clauses = [
                        "\(payeeNameSQL) LIKE ? ESCAPE '\\'",
                        "c.name LIKE ? ESCAPE '\\'",
                        "t.notes LIKE ? ESCAPE '\\'"
                    ]
                    arguments.append(contentsOf: [pattern, pattern, pattern])
                    if let range = matcher.amountCentsRange {
                        clauses.append("ABS(t.amount) BETWEEN ? AND ?")
                        arguments.append(range.lowerBound)
                        arguments.append(range.upperBound)
                    }
                    sql += " AND (" + clauses.joined(separator: " OR ") + ")"
                }
            }

            sql += " ORDER BY t.date DESC, t.sort_order DESC LIMIT ? OFFSET ?"
            arguments.append(limit)
            arguments.append(offset)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))

            // Split parents have no category of their own; carry the live
            // children's category + amount as portions so the list row can
            // show the breakdown ("Food $6.00, Fun $4.00") without opening it.
            let parentIds: [String] = rows.compactMap { row in
                (row["isParent"] == 1) ? row["id"] : nil
            }
            var splitPortions: [String: [Transaction.SplitPortion]] = [:]
            if !parentIds.isEmpty {
                let placeholders = Array(repeating: "?", count: parentIds.count).joined(separator: ", ")
                let childRows = try Row.fetchAll(db, sql: """
                    SELECT ct.parent_id AS parent_id, ct.amount AS amount,
                           c.name AS category_name
                    FROM transactions ct
                    LEFT JOIN category_mapping cm ON cm.id = ct.category
                    LEFT JOIN categories c ON c.id = COALESCE(cm.transferId, ct.category)
                    WHERE ct.parent_id IN (\(placeholders))
                      AND (ct.tombstone = 0 OR ct.tombstone IS NULL)
                    ORDER BY ct.sort_order DESC
                    """, arguments: StatementArguments(parentIds))
                for childRow in childRows {
                    guard let parentId: String = childRow["parent_id"] else { continue }
                    splitPortions[parentId, default: []].append(Transaction.SplitPortion(
                        categoryName: childRow["category_name"],
                        amount: childRow["amount"] ?? 0
                    ))
                }
            }

            return rows.map { row in
                var transaction = Self.mapTransaction(row)
                transaction.splitPortions = splitPortions[transaction.id]
                return transaction
            }
        }
    }

    /// All live children of a split parent, in entry order (descending
    /// sort_order, matching the list convention).
    func fetchChildTransactions(parentId: String) async throws -> [Transaction] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    t.id, t.isParent, t.isChild, t.acct, t.category, t.amount,
                    t.description, t.notes, t.date, t.imported_description,
                    t.schedule,
                    t.transferred_id, t.cleared, t.reconciled, t.sort_order,
                    t.tombstone, t.parent_id,
                    COALESCE(pa.name, p.name) as payee_name,
                    c.name as category_name,
                    p.transfer_acct as transfer_acct
                FROM transactions t
                LEFT JOIN payee_mapping pm ON pm.id = t.description
                LEFT JOIN payees p ON p.id = pm.targetId
                LEFT JOIN accounts pa ON pa.id = p.transfer_acct
                    AND (pa.tombstone = 0 OR pa.tombstone IS NULL)
                LEFT JOIN category_mapping cm ON cm.id = t.category
                LEFT JOIN categories c ON c.id = COALESCE(cm.transferId, t.category)
                WHERE (t.tombstone = 0 OR t.tombstone IS NULL)
                  AND t.parent_id = ?
                ORDER BY t.sort_order DESC
                """, arguments: [parentId])

            return rows.map(Self.mapTransaction)
        }
    }

    /// Highest messages_crdt rowid — the watermark for new-transaction
    /// detection. 0 when the budget has no messages yet.
    func fetchMaxMessageId() async throws -> Int64 {
        try await dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM messages_crdt") ?? 0
        }
    }

    /// Transactions whose first-ever CRDT message landed after `watermark`
    /// and was authored by another device (HLC timestamps end in the 16-char
    /// node id). First message > watermark means the row itself is new, not
    /// an edit to an existing transaction; the creator's node id keeps this
    /// device's own writes (manual adds, Wallet automation) out of the result.
    func fetchTransactionsCreated(afterMessageId watermark: Int64,
                                  excludingNode nodeId: String) async throws -> [Transaction] {
        try await dbQueue.read { db in
            let sql = Self.transactionSelect + """

                  AND t.id IN (
                      SELECT row FROM messages_crdt
                      WHERE dataset = 'transactions'
                      GROUP BY row
                      HAVING MIN(id) > ? AND substr(MIN(timestamp), -16) <> ?
                  )
                ORDER BY t.date DESC, t.sort_order DESC
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [watermark, nodeId])
            return rows.map(Self.mapTransaction)
        }
    }

    /// Cleared balance for one account: what the bank should agree with
    /// during reconciliation. Same aggregate semantics as the fetchAccounts()
    /// balance query (children count, parents excluded, orphaned children of
    /// tombstoned parents excluded), narrowed to cleared rows.
    func clearedBalance(accountId: String) async throws -> Int {
        try await dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(t.amount), 0)
                FROM transactions t
                LEFT JOIN transactions p ON p.id = t.parent_id
                WHERE t.acct = ?
                  AND t.cleared = 1
                  AND t.date IS NOT NULL
                  AND (t.tombstone = 0 OR t.tombstone IS NULL)
                  AND \(Self.aliveChildPredicate(parent: "p"))
                  AND (t.isParent = 0 OR t.isParent IS NULL)
                """, arguments: [accountId]) ?? 0
        }
    }

    /// Cleared / uncleared / reconciled totals for one account in a single
    /// consistent read (GH #134). Reconciled rows are a subset of cleared,
    /// so cleared + uncleared equals the account balance while reconciled is
    /// informational. Same aggregate semantics as the fetchAccounts() balance
    /// query (children count, parents excluded, orphaned children of
    /// tombstoned parents excluded).
    func balanceBreakdown(accountId: String) async throws -> AccountBalanceBreakdown {
        try await dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT
                    COALESCE(SUM(CASE WHEN t.cleared = 1 THEN t.amount ELSE 0 END), 0) AS cleared,
                    COALESCE(SUM(CASE WHEN t.cleared = 0 OR t.cleared IS NULL THEN t.amount ELSE 0 END), 0) AS uncleared,
                    COALESCE(SUM(CASE WHEN t.reconciled = 1 THEN t.amount ELSE 0 END), 0) AS reconciled
                FROM transactions t
                LEFT JOIN transactions p ON p.id = t.parent_id
                WHERE t.acct = ?
                  AND t.date IS NOT NULL
                  AND (t.tombstone = 0 OR t.tombstone IS NULL)
                  AND \(Self.aliveChildPredicate(parent: "p"))
                  AND (t.isParent = 0 OR t.isParent IS NULL)
                """, arguments: [accountId])
            return AccountBalanceBreakdown(
                cleared: row?["cleared"] ?? 0,
                uncleared: row?["uncleared"] ?? 0,
                reconciled: row?["reconciled"] ?? 0
            )
        }
    }

    /// Every live cleared-but-not-yet-reconciled row in an account — parents
    /// and children included, because locking marks each stored row the way
    /// upstream's ungrouped batch update does. No display joins: callers
    /// write these rows back verbatim with only `reconciled` changed.
    func fetchClearedUnreconciledTransactions(accountId: String) async throws -> [Transaction] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    t.id, t.isParent, t.acct, t.category, t.amount,
                    t.description, t.notes, t.date, t.imported_description,
                    t.schedule,
                    t.transferred_id, t.cleared, t.reconciled, t.sort_order,
                    t.tombstone, t.parent_id
                FROM transactions t
                LEFT JOIN transactions p ON p.id = t.parent_id
                WHERE t.acct = ?
                  AND t.cleared = 1
                  AND t.date IS NOT NULL
                  AND (t.reconciled = 0 OR t.reconciled IS NULL)
                  AND (t.tombstone = 0 OR t.tombstone IS NULL)
                  AND \(Self.aliveChildPredicate(parent: "p"))
                ORDER BY t.date DESC, t.sort_order DESC
                """, arguments: [accountId])

            return rows.map { row in
                Transaction(
                    id: row["id"],
                    accountId: row["acct"] ?? "",
                    date: row["date"] ?? 0,
                    amount: row["amount"] ?? 0,
                    payeeId: row["description"],
                    payeeName: nil,
                    categoryId: row["category"],
                    categoryName: nil,
                    notes: row["notes"],
                    cleared: row["cleared"] == 1,
                    reconciled: row["reconciled"] == 1,
                    transferId: row["transferred_id"],
                    isParent: row["isParent"] == 1,
                    parentId: row["parent_id"],
                    tombstone: row["tombstone"] == 1,
                    sortOrder: row["sort_order"],
                    importedPayee: row["imported_description"],
                    schedule: row["schedule"]
                )
            }
        }
    }

    /// Joins + filter shared by the uncategorized list and count queries.
    /// Mirrors the WebUI's "uncategorized" pseudo-account filter
    /// (desktop-client accountFilter('uncategorized')): on-budget account,
    /// no category, not a split parent (children are where categories live),
    /// and not a transfer unless the other side is off-budget — money leaving
    /// the budget still needs a category. Children of tombstoned split
    /// parents are excluded like fetchTransactionsForReports().
    private static let uncategorizedJoins = """
        FROM transactions t
        JOIN accounts a ON a.id = t.acct
        LEFT JOIN payee_mapping pm ON pm.id = t.description
        LEFT JOIN payees p ON p.id = pm.targetId
        LEFT JOIN accounts ta ON ta.id = p.transfer_acct
        LEFT JOIN transactions par ON par.id = t.parent_id
        """

    private static let uncategorizedWhere = """
        WHERE (t.tombstone = 0 OR t.tombstone IS NULL)
          AND t.date IS NOT NULL
          AND (t.isParent = 0 OR t.isParent IS NULL)
          AND \(aliveChildPredicate(parent: "par"))
          AND t.category IS NULL
          AND (a.offbudget = 0 OR a.offbudget IS NULL)
          AND (a.tombstone = 0 OR a.tombstone IS NULL)
          AND (p.transfer_acct IS NULL OR ta.offbudget = 1)
        """

    /// All transactions still needing a category, newest first (GH #26).
    /// Split children carry no payee of their own, so their display name
    /// falls back to the parent's payee.
    func fetchUncategorizedTransactions() async throws -> [Transaction] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    t.id, t.isParent, t.isChild, t.acct, t.category, t.amount,
                    t.description, t.notes, t.date, t.imported_description,
                    t.schedule,
                    t.transferred_id, t.cleared, t.reconciled, t.sort_order,
                    t.tombstone, t.parent_id,
                    COALESCE(pa.name, p.name, ppa.name, pp.name) as payee_name,
                    p.transfer_acct as transfer_acct
                \(Self.uncategorizedJoins)
                -- Transfer payees carry no name; their display name is the
                -- linked account's name (matches Actual's v_payees view).
                LEFT JOIN accounts pa ON pa.id = p.transfer_acct
                    AND (pa.tombstone = 0 OR pa.tombstone IS NULL)
                -- Parent's payee, as the fallback for split children.
                LEFT JOIN payee_mapping ppm ON ppm.id = par.description
                LEFT JOIN payees pp ON pp.id = ppm.targetId
                LEFT JOIN accounts ppa ON ppa.id = pp.transfer_acct
                    AND (ppa.tombstone = 0 OR ppa.tombstone IS NULL)
                \(Self.uncategorizedWhere)
                ORDER BY t.date DESC, t.sort_order DESC
                """)

            return rows.map { row in
                Transaction(
                    id: row["id"],
                    accountId: row["acct"] ?? "",
                    date: row["date"] ?? 0,
                    amount: row["amount"] ?? 0,
                    payeeId: row["description"],
                    payeeName: row["payee_name"],
                    categoryId: nil,
                    categoryName: nil,
                    notes: row["notes"],
                    cleared: row["cleared"] == 1,
                    reconciled: row["reconciled"] == 1,
                    transferId: row["transferred_id"],
                    isParent: row["isParent"] == 1,
                    parentId: row["parent_id"],
                    tombstone: row["tombstone"] == 1,
                    sortOrder: row["sort_order"],
                    importedPayee: row["imported_description"],
                    schedule: row["schedule"],
                    transferAcct: row["transfer_acct"]
                )
            }
        }
    }

    /// Number of transactions `fetchUncategorizedTransactions()` would
    /// return, without materializing the rows (drives the Budget tab link).
    func fetchUncategorizedCount() async throws -> Int {
        try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) \(Self.uncategorizedJoins) \(Self.uncategorizedWhere)") ?? 0
        }
    }

    /// Every transaction that counts toward a category's spend, newest first,
    /// optionally narrowed to one "yyyy-MM" month (GH #56). Mirrors the
    /// budget month's spent query so the list reconciles with the "Spent"
    /// figure the user tapped: split children included (that's where split
    /// spend lives), split parents excluded even when a pre-split category
    /// lingers on the parent row, category ids resolved through
    /// category_mapping, and tombstoned rows / orphaned children /
    /// off-budget accounts filtered out.
    func fetchCategoryTransactions(categoryId: String, month: String?) async throws -> [Transaction] {
        try await dbQueue.read { db in
            var sql = """
                SELECT
                    t.id, t.isParent, t.isChild, t.acct, t.category, t.amount,
                    t.description, t.notes, t.date, t.imported_description,
                    t.schedule,
                    t.transferred_id, t.cleared, t.reconciled, t.sort_order,
                    t.tombstone, t.parent_id,
                    COALESCE(pa.name, p.name, ppa.name, pp.name) as payee_name,
                    c.name as category_name
                FROM transactions t
                JOIN accounts a ON a.id = t.acct
                LEFT JOIN payee_mapping pm ON pm.id = t.description
                LEFT JOIN payees p ON p.id = pm.targetId
                -- Transfer payees carry no name; their display name is the
                -- linked account's name (matches Actual's v_payees view).
                LEFT JOIN accounts pa ON pa.id = p.transfer_acct
                    AND (pa.tombstone = 0 OR pa.tombstone IS NULL)
                -- Parent's payee, as the fallback for split children.
                LEFT JOIN transactions par ON par.id = t.parent_id
                LEFT JOIN payee_mapping ppm ON ppm.id = par.description
                LEFT JOIN payees pp ON pp.id = ppm.targetId
                LEFT JOIN accounts ppa ON ppa.id = pp.transfer_acct
                    AND (ppa.tombstone = 0 OR ppa.tombstone IS NULL)
                LEFT JOIN category_mapping cm ON cm.id = t.category
                LEFT JOIN categories c ON c.id = COALESCE(cm.transferId, t.category)
                WHERE (t.tombstone = 0 OR t.tombstone IS NULL)
                  AND t.date IS NOT NULL
                  AND \(Self.aliveChildPredicate(parent: "par"))
                  AND (t.isParent = 0 OR t.isParent IS NULL)
                  AND COALESCE(cm.transferId, t.category) = ?
                  AND a.offbudget = 0
                  AND (a.tombstone = 0 OR a.tombstone IS NULL)
                """

            var arguments: [DatabaseValueConvertible] = [categoryId]

            // Dates are YYYYMMDD ints, so date/100 is the YYYYMM month.
            if let month, let monthInt = Int(month.replacingOccurrences(of: "-", with: "")) {
                sql += " AND (t.date / 100) = ?"
                arguments.append(monthInt)
            }

            sql += " ORDER BY t.date DESC, t.sort_order DESC"

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))

            return rows.map { row in
                Transaction(
                    id: row["id"],
                    accountId: row["acct"] ?? "",
                    date: row["date"] ?? 0,
                    amount: row["amount"] ?? 0,
                    payeeId: row["description"],
                    payeeName: row["payee_name"],
                    categoryId: row["category"],
                    categoryName: row["category_name"],
                    notes: row["notes"],
                    cleared: row["cleared"] == 1,
                    reconciled: row["reconciled"] == 1,
                    transferId: row["transferred_id"],
                    isParent: row["isParent"] == 1,
                    parentId: row["parent_id"],
                    tombstone: row["tombstone"] == 1,
                    sortOrder: row["sort_order"],
                    importedPayee: row["imported_description"],
                    schedule: row["schedule"]
                )
            }
        }
    }

    // MARK: - Categories

    func fetchCategoryGroups() async throws -> [CategoryGroup] {
        try await dbQueue.read { db in
            let groupRecords = try CategoryGroupRecord
                .filter(Column("tombstone") == 0 || Column("tombstone") == nil)
                .order(Column("sort_order").asc)
                .fetchAll(db)

            let categoryRecords = try CategoryRecord
                .filter(Column("tombstone") == 0 || Column("tombstone") == nil)
                .order(Column("sort_order").asc)
                .fetchAll(db)

            return groupRecords.map { group in
                let categories = categoryRecords
                    .filter { $0.catGroup == group.id }
                    .map { cat in
                        Category(
                            id: cat.id,
                            name: cat.name ?? "Unknown",
                            groupId: cat.catGroup ?? "",
                            isIncome: cat.isIncome == 1,
                            hidden: cat.hidden == 1,
                            sortOrder: cat.sortOrder ?? 0
                        )
                    }

                return CategoryGroup(
                    id: group.id,
                    name: group.name ?? "Unknown",
                    isIncome: group.isIncome == 1,
                    hidden: group.hidden == 1,
                    sortOrder: group.sortOrder ?? 0,
                    categories: categories
                )
            }
        }
    }
    
    /// Everything a category insert wrote: the new row, plus the siblings the
    /// shove had to move to make room for it.
    struct CategoryInsertion: Equatable {
        let category: Category
        let movedSiblings: [SortOrder.Position]
    }

    /// Refusals that come from the budget's own contents rather than SQLite,
    /// worded for the person who typed the name. Upstream rejects the same
    /// two cases in `insertCategoryGroup` / `insertCategory`.
    enum CategoryWriteError: LocalizedError, Equatable {
        case duplicateGroupName(String)
        case duplicateCategoryName(name: String, groupName: String)
        case groupNotFound
        case categoryNotFound

        var errorDescription: String? {
            switch self {
            case .duplicateGroupName(let name):
                return "A category group named \"\(name)\" already exists"
            case .duplicateCategoryName(let name, let groupName):
                return "\(groupName) already has a category named \"\(name)\""
            case .groupNotFound:
                return "That category group no longer exists"
            case .categoryNotFound:
                return "That category no longer exists"
            }
        }
    }

    /// Validate a category rename before the sync layer emits its name
    /// message. Names remain unique within a group, matching category
    /// creation and the web app.
    func validateCategoryRename(id: String, name: String) throws {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT cat_group FROM categories
                WHERE id = ? AND tombstone IS NOT 1
                """, arguments: [id])
            guard let row else { throw CategoryWriteError.categoryNotFound }
            let groupId: String = row["cat_group"] ?? ""
            let groupName = try String.fetchOne(db, sql: """
                SELECT name FROM category_groups
                WHERE id = ? AND tombstone IS NOT 1
                """, arguments: [groupId]) ?? "That group"
            let clash = try Bool.fetchOne(db, sql: """
                SELECT 1 FROM categories
                WHERE cat_group = ? AND id != ? AND UPPER(name) = UPPER(?)
                  AND tombstone IS NOT 1
                LIMIT 1
                """, arguments: [groupId, id, name]) ?? false
            if clash {
                throw CategoryWriteError.duplicateCategoryName(
                    name: name,
                    groupName: groupName
                )
            }
        }
    }

    /// Create a category group after every existing one, mirroring upstream
    /// `insertCategoryGroup`: names are unique across the whole budget
    /// (case-insensitively), and the group sorts one increment past the last.
    /// Returns the row as written, so the caller can turn it into CRDT
    /// messages.
    func insertCategoryGroup(id: String, name: String) throws -> CategoryGroup {
        try dbQueue.write { db in
            let clash = try String.fetchOne(db, sql: """
                SELECT name FROM category_groups
                WHERE UPPER(name) = UPPER(?) AND tombstone IS NOT 1
                LIMIT 1
                """, arguments: [name])
            if let clash {
                throw CategoryWriteError.duplicateGroupName(clash)
            }

            let lastSortOrder = try Double.fetchOne(db, sql: """
                SELECT sort_order FROM category_groups
                WHERE tombstone IS NOT 1
                ORDER BY sort_order DESC, id DESC
                LIMIT 1
                """) ?? 0

            let group = CategoryGroup(
                id: id,
                name: name,
                isIncome: false,
                hidden: false,
                sortOrder: lastSortOrder + SortOrder.increment,
                categories: []
            )

            try db.execute(sql: """
                INSERT INTO category_groups (id, name, is_income, hidden, tombstone, sort_order)
                VALUES (?, ?, 0, 0, 0, ?)
                """, arguments: [group.id, group.name, group.sortOrder])

            return group
        }
    }

    /// Create a category at the top of its group, mirroring upstream
    /// `insertCategory`: names are unique within the group, the new row takes
    /// its group's income and hidden flags, and it gets the self-referencing
    /// `category_mapping` row every read path joins through. Siblings the
    /// shove moved are written here too and returned for the caller's CRDT
    /// messages.
    func insertCategory(id: String, name: String, groupId: String) throws -> CategoryInsertion {
        try dbQueue.write { db in
            let group = try Row.fetchOne(db, sql: """
                SELECT name, is_income, hidden FROM category_groups
                WHERE id = ? AND tombstone IS NOT 1
                """, arguments: [groupId])
            guard let group else {
                throw CategoryWriteError.groupNotFound
            }
            let groupName: String = group["name"] ?? "That group"

            let clash = try Bool.fetchOne(db, sql: """
                SELECT 1 FROM categories
                WHERE cat_group = ? AND UPPER(name) = UPPER(?) AND tombstone IS NOT 1
                LIMIT 1
                """, arguments: [groupId, name]) ?? false
            if clash {
                throw CategoryWriteError.duplicateCategoryName(name: name, groupName: groupName)
            }

            let siblings = try Row.fetchAll(db, sql: """
                SELECT id, sort_order FROM categories
                WHERE cat_group = ? AND tombstone IS NOT 1
                ORDER BY sort_order, id
                """, arguments: [groupId]).map { row in
                SortOrder.Position(id: row["id"], sortOrder: row["sort_order"] ?? 0)
            }
            let placement = SortOrder.shove(siblings, before: siblings.first?.id)

            for moved in placement.moved {
                try db.execute(
                    sql: "UPDATE categories SET sort_order = ? WHERE id = ?",
                    arguments: [moved.sortOrder, moved.id])
            }

            let category = Category(
                id: id,
                name: name,
                groupId: groupId,
                isIncome: group["is_income"] == 1,
                hidden: group["hidden"] == 1,
                sortOrder: placement.sortOrder
            )

            try db.execute(sql: """
                INSERT INTO categories (id, name, cat_group, is_income, hidden, tombstone, sort_order)
                VALUES (?, ?, ?, ?, ?, 0, ?)
                """, arguments: [
                    category.id,
                    category.name,
                    category.groupId,
                    category.isIncome ? 1 : 0,
                    category.hidden ? 1 : 0,
                    category.sortOrder
                ])
            try db.execute(sql: """
                INSERT INTO category_mapping (id, transferId)
                VALUES (?, ?)
                """, arguments: [category.id, category.id])

            return CategoryInsertion(category: category, movedSiblings: placement.moved)
        }
    }

    // MARK: - Payees

    func fetchPayees() async throws -> [Payee] {
        try await dbQueue.read { db in
            let records = try PayeeRecord
                .filter(Column("tombstone") == 0 || Column("tombstone") == nil)
                .order(Column("name").asc)
                .fetchAll(db)

            return records.map { record in
                Payee(
                    id: record.id,
                    name: record.name ?? "Unknown",
                    transferAccountId: record.transferAcct
                )
            }
        }
    }

    // MARK: - Transaction Category History

    /// Returns the category id of the most recent non-tombstoned transaction for `payeeId`
    /// where category is non-null. Returns nil if no such transaction exists.
    ///
    /// Note: in this schema `description` stores the payee id (per `Transaction.syncableFields`).
    func mostRecentCategoryId(forPayeeId payeeId: String) async throws -> String? {
        try await dbQueue.read { db in
            try String.fetchOne(db, sql: """
                SELECT category FROM transactions
                WHERE description = ?
                  AND (tombstone = 0 OR tombstone IS NULL)
                  AND category IS NOT NULL
                ORDER BY date DESC, sort_order DESC
                LIMIT 1
            """, arguments: [payeeId])
        }
    }

    #if DEBUG
    /// Test-only escape hatch so unit tests can seed the database directly.
    /// Do NOT call from production code.
    var dbQueueForTesting: DatabaseQueue { dbQueue }
    #endif

    // MARK: - Budget Data

    func fetchBudgetMonth(month: String) async throws -> BudgetMonth {
        try await dbQueue.read { db in
            let targetMonthInt = Self.monthStringToInt(month)

            // Detect which budget table the budget uses.
            // Envelope (zero_budgets) clamps negative leftover to 0 unless
            // the carryover flag is set. Tracking (reflect_budgets) drops
            // any prior leftover entirely unless the flag is set.
            let budgetsTable = try Self.budgetTable(db)
            let isEnvelope = budgetsTable != "reflect_budgets"

            // Bulk-load all budget rows up to and including the target month.
            // months are YYYYMM ints in the budgets tables.
            // (budgeted, carryFlag) keyed by (monthInt, categoryId).
            var budgetByMonthCat: [Int: [String: (amount: Int, flag: Bool)]] = [:]
            if let budgetsTable {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT month, category, amount, carryover
                    FROM \(budgetsTable)
                    WHERE month <= ?
                    """, arguments: [targetMonthInt])
                for row in rows {
                    let m: Int = row["month"] ?? 0
                    guard m > 0, let categoryId: String = row["category"] else { continue }
                    let amount: Int = row["amount"] ?? 0
                    let flagInt: Int = row["carryover"] ?? 0
                    budgetByMonthCat[m, default: [:]][categoryId] = (amount, flagInt == 1)
                }
            }

            // Bulk-load spent per (YYYYMM, category) up to and including the
            // target month. date is YYYYMMDD, so date / 100 = YYYYMM.
            // Mirrors Actual's own spent query (loot-core base.ts
            // getSumAmountsByMonth over v_transactions_internal_alive):
            //   * Resolve the category through category_mapping — merged/renamed
            //     categories keep the old id on their transactions but point it
            //     at the surviving id, so we must group by the mapped id.
            //   * Only count on-budget accounts (accounts.offbudget = 0). A
            //     categorised transaction in an off-budget account is not budget
            //     spending.
            //   * Also skip deleted accounts (accounts.tombstone = 1). Upstream
            //     doesn't check this, because deleteAccount() tombstones or
            //     reassigns every transaction on its way out; a live transaction
            //     left on a deleted account is a sync-race orphan (upstream's own
            //     TODO in accounts/app.ts) that nothing else in the app counts.
            //   * Do NOT filter transfers. On-budget↔on-budget transfers carry no
            //     category (excluded by category IS NOT NULL); a categorised leg
            //     is a transfer to an off-budget account, which Actual counts as
            //     spent.
            //   * Exclude split parents (isParent = 1). A transaction categorised
            //     BEFORE being split keeps its category on the parent row —
            //     Actual's splitTransaction() never clears it, it only masks it
            //     in the view layer (CASE WHEN isParent = 1 THEN NULL). Counting
            //     the parent on top of its children doubles that month's spent.
            //   * Exclude split children whose parent is tombstoned. Deleting a
            //     split tombstones the parent but leaves the child rows with
            //     tombstone = 0, so a per-row tombstone check alone still counts
            //     those orphans. Actual's alive view (v_transactions_layer1)
            //     requires the parent to be alive too.
            let spentRows = try Row.fetchAll(db, sql: """
                SELECT
                    (t.date / 100) AS month,
                    COALESCE(cm.transferId, t.category) AS category_id,
                    SUM(t.amount) AS spent
                FROM transactions t
                LEFT JOIN category_mapping cm ON cm.id = t.category
                LEFT JOIN accounts a ON a.id = t.acct
                LEFT JOIN transactions p ON p.id = t.parent_id
                WHERE (t.tombstone = 0 OR t.tombstone IS NULL)
                  AND \(Self.aliveChildPredicate(parent: "p"))
                  AND (t.isParent = 0 OR t.isParent IS NULL)
                  AND t.category IS NOT NULL
                  AND a.offbudget = 0
                  AND (a.tombstone = 0 OR a.tombstone IS NULL)
                  AND (t.date / 100) <= ?
                GROUP BY (t.date / 100), COALESCE(cm.transferId, t.category)
                """, arguments: [targetMonthInt])
            var spentByMonthCat: [Int: [String: Int]] = [:]
            for row in spentRows {
                let m: Int = row["month"] ?? 0
                guard m > 0, let categoryId: String = row["category_id"] else { continue }
                let spent: Int = row["spent"] ?? 0
                spentByMonthCat[m, default: [:]][categoryId] = spent
            }

            // "Hold for next month" amounts, keyed by YYYYMM. Upstream writes
            // zero_budget_months ids as sheet month strings ("2026-07"); parse
            // digits defensively in case another client wrote "202607".
            var bufferedByMonth: [Int: Int] = [:]
            if isEnvelope, try db.tableExists("zero_budget_months") {
                let bufferRows = try Row.fetchAll(db, sql: "SELECT id, buffered FROM zero_budget_months")
                for row in bufferRows {
                    guard let id: String = row["id"],
                          let m = Int(id.filter(\.isNumber)),
                          (1...12).contains(m % 100),
                          m <= targetMonthInt else { continue }
                    bufferedByMonth[m] = row["buffered"] ?? 0
                }
            }

            // Category id sets for the envelope "to budget" math. Hidden
            // categories still count toward the totals (upstream includes
            // them in the summary sheet); only tombstoned ones drop out.
            let categories = try CategoryRecord
                .filter(Column("tombstone") == 0 || Column("tombstone") == nil)
                .fetchAll(db)
            let incomeCatIds = Set(categories.filter { $0.isIncome == 1 }.map { $0.id })
            let expenseCatIds = Set(categories.filter { $0.isIncome != 1 }.map { $0.id })

            // Determine the earliest month we need to walk from. min over any
            // budget row, spent row, or held amount. If none, just use the target.
            let earliestMonth: Int = {
                let candidates = Array(budgetByMonthCat.keys) + Array(spentByMonthCat.keys)
                    + Array(bufferedByMonth.keys)
                return candidates.min() ?? targetMonthInt
            }()

            // Walk forward month-by-month, computing leftover per category.
            // leftover[cat] holds the *running* leftover up to and including
            // the most recently processed month.
            var runningLeftover: [String: Int] = [:]
            // The carryover flag applied at the boundary M -> M+1 is the
            // flag stored on month M (the source month). Track it across
            // iterations so the next month knows whether to clamp.
            var lastFlag: [String: Bool] = [:]

            // Envelope "To Budget" accumulators (mirrors loot-core
            // envelope.ts createSummary):
            //   to-budget = income + from-last-month + last-month-overspent
            //               - budgeted - buffered
            // where from-last-month = prior to-budget + prior buffered, and
            // last-month-overspent is the negative leftover the clamp below
            // strips from categories — that debt comes out of this month's
            // unallocated funds instead.
            var runningToBudget = 0
            var priorBuffered = 0

            var m = earliestMonth
            while m <= targetMonthInt {
                let budgetsForMonth = budgetByMonthCat[m] ?? [:]
                let spentForMonth = spentByMonthCat[m] ?? [:]

                if isEnvelope {
                    var income = 0
                    var bufferedAuto = 0
                    for cat in incomeCatIds {
                        let amount = spentForMonth[cat] ?? 0
                        income += amount
                        // Income marked "carryover" is auto-held for next
                        // month unless a manual hold overrides it.
                        if budgetsForMonth[cat]?.flag == true {
                            bufferedAuto += amount
                        }
                    }
                    var budgetedTotal = 0
                    var lastMonthOverspent = 0
                    for cat in expenseCatIds {
                        budgetedTotal += budgetsForMonth[cat]?.amount ?? 0
                        if !(lastFlag[cat] ?? false) {
                            lastMonthOverspent += min(0, runningLeftover[cat] ?? 0)
                        }
                    }
                    let manualBuffered = bufferedByMonth[m] ?? 0
                    let buffered = manualBuffered != 0 ? manualBuffered : bufferedAuto
                    runningToBudget = income + runningToBudget + priorBuffered
                        + lastMonthOverspent - budgetedTotal - buffered
                    priorBuffered = buffered
                }

                let touchedCats = Set(budgetsForMonth.keys)
                    .union(spentForMonth.keys)
                    .union(runningLeftover.keys)

                var nextLeftover: [String: Int] = [:]
                var nextFlag: [String: Bool] = [:]
                for cat in touchedCats {
                    let budgeted = budgetsForMonth[cat]?.amount ?? 0
                    let spent = spentForMonth[cat] ?? 0
                    let prior = runningLeftover[cat] ?? 0
                    let priorFlag = lastFlag[cat] ?? false

                    // Contribution of the prior month's leftover into this month.
                    let contribution: Int
                    if priorFlag {
                        contribution = prior
                    } else if isEnvelope {
                        contribution = max(0, prior)
                    } else {
                        contribution = 0
                    }

                    nextLeftover[cat] = budgeted + spent + contribution
                    nextFlag[cat] = budgetsForMonth[cat]?.flag ?? false
                }
                runningLeftover = nextLeftover
                lastFlag = nextFlag

                m = Self.nextMonth(from: m)
            }

            // Surface the values for the target month.
            let targetBudgets = budgetByMonthCat[targetMonthInt] ?? [:]
            let targetSpent = spentByMonthCat[targetMonthInt] ?? [:]
            // The "carryover into target month" is the prior month's leftover
            // contribution (post clamp / flag). Reverse-derive by recomputing
            // available - budgeted - spent for each category we touched.

            let groups = try CategoryGroupRecord
                .filter(Column("tombstone") == 0 || Column("tombstone") == nil)
                .fetchAll(db)
            let visibleGroupIds = Set(groups.filter { $0.hidden != 1 }.map { $0.id })
            let groupsById = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })

            let categoryBudgets = categories.compactMap { cat -> CategoryBudget? in
                guard cat.isIncome != 1 else { return nil }
                guard cat.hidden != 1 else { return nil }
                guard visibleGroupIds.contains(cat.catGroup ?? "") else { return nil }
                let budgeted = targetBudgets[cat.id]?.amount ?? 0
                let spent = targetSpent[cat.id] ?? 0
                let available = runningLeftover[cat.id] ?? (budgeted + spent)
                let priorContribution = available - budgeted - spent
                let group = groupsById[cat.catGroup ?? ""]

                return CategoryBudget(
                    month: month,
                    categoryId: cat.id,
                    categoryName: cat.name ?? "Unknown",
                    groupId: cat.catGroup ?? "",
                    groupName: group?.name ?? "Unknown",
                    groupSortOrder: group?.sortOrder ?? .greatestFiniteMagnitude,
                    categorySortOrder: cat.sortOrder ?? .greatestFiniteMagnitude,
                    budgeted: budgeted,
                    spent: spent,
                    available: available,
                    carryover: priorContribution
                )
            }

            // Income categories, shown as their own section like the web
            // UI's Income group. "Received" is the month's net activity on
            // the category (income transactions are positive amounts).
            let incomeCategories = categories.compactMap { cat -> IncomeCategory? in
                guard cat.isIncome == 1 else { return nil }
                guard cat.hidden != 1 else { return nil }
                guard visibleGroupIds.contains(cat.catGroup ?? "") else { return nil }
                let group = groupsById[cat.catGroup ?? ""]

                return IncomeCategory(
                    month: month,
                    categoryId: cat.id,
                    categoryName: cat.name ?? "Unknown",
                    groupName: group?.name ?? "Income",
                    sortOrder: cat.sortOrder ?? .greatestFiniteMagnitude,
                    budgeted: targetBudgets[cat.id]?.amount ?? 0,
                    received: targetSpent[cat.id] ?? 0
                )
            }
            .sorted { $0.sortOrder < $1.sortOrder }

            return BudgetMonth(
                month: month,
                categoryBudgets: categoryBudgets,
                incomeCategories: incomeCategories,
                toBudget: isEnvelope ? runningToBudget : nil
            )
        }
    }

    // MARK: - Notes

    /// The note stored for one row of the budget — a category (GH #131) or an
    /// account (GH #198). Actual's `notes` table is keyed by the annotated
    /// row's own id, so the note lives at `notes.id = <the row's id>` whatever
    /// kind of row it is.
    ///
    /// One read reports both whether the file has the table and what it holds,
    /// so the caller can distinguish "this file can't store notes" from "this
    /// row has none" without a second round trip or a cached capability flag
    /// that could go stale when the open file changes.
    func fetchNote(id: String) async throws -> EntityNote {
        try await dbQueue.read { db in
            guard try db.tableExists("notes") else { return .unsupported }
            // A row can exist with a NULL note (another client cleared it that
            // way); that reads as empty, same as no row at all.
            let note = try String.fetchOne(
                db, sql: "SELECT note FROM notes WHERE id = ?", arguments: [id])
            return EntityNote(supported: true, text: note ?? "")
        }
    }

    /// Whether this file has the `notes` table, for `SyncClient`'s write guard.
    /// Sync (see the async/sync split above): the write path can't suspend.
    func notesTableExists() throws -> Bool {
        try dbQueue.read { db in try db.tableExists("notes") }
    }

    /// Where a budget amount write for (month, category) must land: which
    /// budget table this file uses, and the row to update or create.
    struct BudgetCellRef: Equatable {
        let table: String   // "zero_budgets" (envelope) or "reflect_budgets" (tracking)
        let rowId: String
        let monthInt: Int   // YYYYMM
        let exists: Bool
        /// Current budgeted amount in cents (0 when the row doesn't exist),
        /// read in the same transaction as the row lookup so transfer writes
        /// compute source-minus / destination-plus from a consistent snapshot.
        let amount: Int
    }

    /// Resolve the budget cell for a month ("2026-07") and category. Mirrors
    /// upstream setBudget (loot-core budget/actions.ts): look the row up by
    /// (month, category) and reuse its id — rows written by other clients may
    /// not follow the {YYYYMM}-{categoryId} convention, and inserting a second
    /// row for the same cell would fork it. Returns nil when the file has no
    /// budget table or the month string is malformed.
    func budgetCell(month: String, categoryId: String) throws -> BudgetCellRef? {
        let monthInt = Self.monthStringToInt(month)
        guard monthInt > 0 else { return nil }

        return try dbQueue.read { db in
            guard let table = try Self.budgetTable(db) else { return nil }

            let existing = try Row.fetchOne(db, sql: """
                SELECT id, amount FROM \(table) WHERE month = ? AND category = ?
                """, arguments: [monthInt, categoryId])

            return BudgetCellRef(
                table: table,
                rowId: existing?["id"] ?? "\(monthInt)-\(categoryId)",
                monthInt: monthInt,
                exists: existing != nil,
                amount: existing?["amount"] ?? 0
            )
        }
    }

    /// Which budget table this file uses, or nil when it has neither. Real
    /// Actual files contain BOTH zero_budgets and reflect_budgets (loot-core's
    /// migrations create them unconditionally), so table existence says
    /// nothing — the budgetType preference is the only signal of which one is
    /// live: 'tracking' ('report' before the Actual 25.5 rename migration)
    /// means reflect_budgets; anything else, including no row at all, means
    /// envelope, matching upstream's default. When only one table exists the
    /// preference can't override it — writing into a missing table would fail.
    private static func budgetTable(_ db: Database) throws -> String? {
        let hasZero = try db.tableExists("zero_budgets")
        let hasReflect = try db.tableExists("reflect_budgets")
        guard hasZero, hasReflect else {
            if hasZero { return "zero_budgets" }
            if hasReflect { return "reflect_budgets" }
            return nil
        }

        var isTracking = false
        if try db.tableExists("preferences") {
            let value = try String.fetchOne(
                db, sql: "SELECT value FROM preferences WHERE id = 'budgetType'")
            isTracking = value == "tracking" || value == "report"
        }
        return isTracking ? "reflect_budgets" : "zero_budgets"
    }

    private static func monthStringToInt(_ month: String) -> Int {
        // Convert "2025-12" to 202512
        let parts = month.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]),
              let monthNum = Int(parts[1]) else {
            return 0
        }
        return year * 100 + monthNum
    }

    private static func nextMonth(from monthInt: Int) -> Int {
        // Convert 202512 -> 202601
        let year = monthInt / 100
        let month = monthInt % 100
        if month == 12 {
            return (year + 1) * 100 + 1
        }
        return year * 100 + month + 1
    }

    // MARK: - Clock Storage

    struct ClockRecord: Codable {
        let timestamp: String
        let merkle: MerkleNode
    }

    func loadClock() throws -> ClockRecord? {
        try dbQueue.read { db in
            // Check if table exists first
            let tableExists = try db.tableExists("messages_clock")
            guard tableExists else {
                logger.info("messages_clock table doesn't exist, starting fresh")
                return nil
            }

            let row = try Row.fetchOne(db, sql: "SELECT clock FROM messages_clock WHERE id = 1")
            guard let clockJson: String = row?["clock"] else { return nil }
            guard let data = clockJson.data(using: .utf8) else { return nil }

            // Try to decode as our ClockRecord format first
            if let record = try? JSONDecoder().decode(ClockRecord.self, from: data) {
                return record
            }

            // Fallback: Actual stores just the merkle tree directly, not wrapped in ClockRecord
            // Try to decode as just a MerkleNode
            if let merkle = try? JSONDecoder().decode(MerkleNode.self, from: data) {
                logger.info("Loaded legacy clock format (merkle only)")
                return ClockRecord(timestamp: "", merkle: merkle)
            }

            // If neither works, log and return nil to start fresh
            logger.notice("Could not decode clock data, starting fresh")
            return nil
        }
    }

    func saveClock(_ clock: ClockRecord) throws {
        let data = try JSONEncoder().encode(clock)
        guard let json = String(data: data, encoding: .utf8) else { return }

        try dbQueue.write { db in
            // Create table if it doesn't exist
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS messages_clock (
                    id INTEGER PRIMARY KEY,
                    clock TEXT
                )
                """)

            try db.execute(
                sql: "INSERT OR REPLACE INTO messages_clock (id, clock) VALUES (1, ?)",
                arguments: [json]
            )
        }
    }

    // MARK: - Dashboard Widgets

    /// Returns transactions suitable for report aggregation:
    /// - Excludes tombstoned rows
    /// - Excludes split PARENTS (their amount equals the sum of children, so
    ///   including both would double-count, and parents have no category which
    ///   breaks category-based conditions)
    /// - Includes split children (where category lives) and standalone txs
    func fetchTransactionsForReports() async throws -> [Transaction] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    t.id, t.isParent, t.isChild, t.acct, t.category, t.amount,
                    t.description, t.notes, t.date, t.imported_description,
                    t.schedule,
                    t.transferred_id, t.cleared, t.reconciled, t.sort_order,
                    t.tombstone, t.parent_id,
                    COALESCE(pa.name, p.name) as payee_name,
                    p.transfer_acct as transfer_acct,
                    c.name as category_name
                FROM transactions t
                LEFT JOIN payee_mapping pm ON pm.id = t.description
                LEFT JOIN payees p ON p.id = pm.targetId
                -- Transfer payees carry no name; their display name is the
                -- linked account's name (matches Actual's v_payees view).
                LEFT JOIN accounts pa ON pa.id = p.transfer_acct
                    AND (pa.tombstone = 0 OR pa.tombstone IS NULL)
                LEFT JOIN category_mapping cm ON cm.id = t.category
                LEFT JOIN categories c ON c.id = COALESCE(cm.transferId, t.category)
                -- Deleting a split tombstones only the parent; its children
                -- keep tombstone = 0, so they must be excluded via the parent
                -- (same rule as the fetchAccounts() balance query).
                LEFT JOIN transactions par ON par.id = t.parent_id
                WHERE (t.tombstone = 0 OR t.tombstone IS NULL)
                  AND (t.isParent = 0 OR t.isParent IS NULL)
                  AND \(Self.aliveChildPredicate(parent: "par"))
                  AND t.date IS NOT NULL
                  AND t.acct IS NOT NULL
                """)

            return rows.map { row in
                Transaction(
                    id: row["id"],
                    accountId: row["acct"] ?? "",
                    date: row["date"] ?? 0,
                    amount: row["amount"] ?? 0,
                    payeeId: row["description"],
                    payeeName: row["payee_name"],
                    categoryId: row["category"],
                    categoryName: row["category_name"],
                    notes: row["notes"],
                    cleared: row["cleared"] == 1,
                    reconciled: row["reconciled"] == 1,
                    transferId: row["transferred_id"],
                    isParent: row["isParent"] == 1,
                    parentId: row["parent_id"],
                    tombstone: row["tombstone"] == 1,
                    sortOrder: row["sort_order"],
                    importedPayee: row["imported_description"],
                    schedule: row["schedule"],
                    transferAcct: row["transfer_acct"]
                )
            }
        }
    }

    /// Returns raw (id, type, metaJSON) triples for every non-tombstoned
    /// dashboard widget. Useful for sharing exact widget configuration when
    /// triaging report rendering bugs.
    func dumpDashboardRows() async throws -> [(id: String, type: String, metaJSON: String)] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, type, meta
                FROM dashboard
                WHERE (tombstone = 0 OR tombstone IS NULL)
                ORDER BY y ASC, x ASC
                """)
            return rows.compactMap { row in
                guard let id = row["id"] as String?,
                      let type = row["type"] as String? else { return nil }
                let meta = (row["meta"] as String?) ?? "null"
                return (id: id, type: type, metaJSON: meta)
            }
        }
    }

    /// Live dashboard pages in table order — the same order the web app's
    /// unordered AQL select (`q('dashboard_pages').select('*')`) yields and
    /// its router indexes into for the default dashboard
    /// (ReportsDashboardRouter → dashboardPages[0]).
    func fetchDashboardPages() async throws -> [DashboardPage] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, name FROM dashboard_pages
                WHERE (tombstone = 0 OR tombstone IS NULL)
                ORDER BY rowid ASC
                """)
            return rows.compactMap { row -> DashboardPage? in
                guard let id = row["id"] as String? else { return nil }
                return DashboardPage(id: id, name: (row["name"] as String?) ?? "")
            }
        }
    }

    /// Live widgets on one dashboard page, in reading order (y, then x).
    /// The web app treats pages as separate dashboards (GH #120: rendering
    /// only one merged view scrambled multi-dashboard budgets), so widgets
    /// on other, deleted, or unknown pages must not render for a given page.
    /// Upstream's migration mints a fresh "Main" page id on every client
    /// that runs it, so a synced budget can carry full duplicate widget sets
    /// under orphaned page ids (GH: Reports showed every widget twice).
    ///
    /// A nil `pageId` selects pageless widgets — budgets from servers that
    /// predate multiple dashboards carry no page rows or ids.
    func fetchWidgets(pageId: String?) async throws -> [DashboardWidget] {
        try await dbQueue.read { db in
            let rows: [Row]
            if let pageId {
                rows = try Row.fetchAll(db, sql: """
                    SELECT id, type, meta
                    FROM dashboard
                    WHERE (tombstone = 0 OR tombstone IS NULL)
                      AND dashboard_page_id = ?
                    ORDER BY y ASC, x ASC
                    """, arguments: [pageId])
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT id, type, meta
                    FROM dashboard
                    WHERE (tombstone = 0 OR tombstone IS NULL)
                      AND dashboard_page_id IS NULL
                    ORDER BY y ASC, x ASC
                    """)
            }

            return rows.compactMap { row -> DashboardWidget? in
                guard let id = row["id"] as String?,
                      let type = row["type"] as String? else {
                    return nil
                }
                let metaJSON = row["meta"] as String?
                return DashboardWidget.parse(id: id, type: type, metaJSON: metaJSON)
            }
        }
    }

    /// Loads the referenced `custom_reports` rows keyed by id. Tombstoned
    /// rows and unknown ids are simply absent from the result.
    func fetchCustomReportConfigs(ids: [String]) async throws -> [String: CustomReportConfig] {
        guard !ids.isEmpty else { return [:] }
        return try await dbQueue.read { db in
            // The app's own migration (1770000000002) creates custom_reports
            // without upstream's later columns (date_static, include_current,
            // sort_by); a synced budget file has all of them. Select what
            // exists and default the rest.
            let existing = Set(try db.columns(in: "custom_reports").map(\.name))
            let wanted = [
                "id", "name", "mode", "group_by", "balance_type", "interval",
                "graph_type", "date_range", "date_static", "start_date",
                "end_date", "include_current", "show_empty", "show_offbudget",
                "show_hidden", "show_uncategorized", "sort_by", "conditions",
                "conditions_op"
            ]
            let select = wanted
                .map { existing.contains($0) ? $0 : "NULL AS \($0)" }
                .joined(separator: ", ")
            let marks = ids.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT \(select)
                FROM custom_reports
                WHERE id IN (\(marks)) AND (tombstone = 0 OR tombstone IS NULL)
                """, arguments: StatementArguments(ids))
            var out: [String: CustomReportConfig] = [:]
            for row in rows {
                let conditions = (row["conditions"] as String?)
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONDecoder().decode([WidgetRuleCondition].self, from: $0) }
                let config = CustomReportConfig(
                    id: row["id"],
                    name: row["name"] ?? "Custom Report",
                    mode: row["mode"] ?? "total",
                    groupBy: row["group_by"] ?? "Category",
                    balanceType: row["balance_type"] ?? "Payment",
                    interval: row["interval"] ?? "Monthly",
                    graphType: row["graph_type"] ?? "BarGraph",
                    dateRange: row["date_range"],
                    dateStatic: (row["date_static"] as Int? ?? 0) != 0,
                    startDate: row["start_date"],
                    endDate: row["end_date"],
                    includeCurrent: (row["include_current"] as Int? ?? 0) != 0,
                    showEmpty: (row["show_empty"] as Int? ?? 0) != 0,
                    showOffBudget: (row["show_offbudget"] as Int? ?? 0) != 0,
                    showHidden: (row["show_hidden"] as Int? ?? 0) != 0,
                    showUncategorized: (row["show_uncategorized"] as Int? ?? 0) != 0,
                    sortBy: row["sort_by"] ?? "desc",
                    conditions: conditions,
                    conditionsOp: row["conditions_op"] ?? "and"
                )
                out[config.id] = config
            }
            return out
        }
    }

    /// Synced pref controlling week bucketing (0 = Sunday … 6 = Saturday).
    /// Budget rows for report engines from the live budgets table (see
    /// budgetTable(_:)), plus whether that table is reflect_budgets so
    /// callers can mirror upstream budgetType checks.
    struct ReportBudgetData: Equatable {
        var entries: [BudgetAnalysisBudgetEntry] = []
        var isTracking = false
    }

    func fetchBudgetDataForReports() async throws -> ReportBudgetData {
        try await dbQueue.read { db in
            guard let table = try Self.budgetTable(db) else { return ReportBudgetData() }
            let rows = try Row.fetchAll(db, sql: """
                SELECT b.month, COALESCE(cm.transferId, b.category) AS category, b.amount
                FROM \(table) b
                LEFT JOIN category_mapping cm ON cm.id = b.category
                WHERE b.category IS NOT NULL
                """)
            let entries = rows.compactMap { row -> BudgetAnalysisBudgetEntry? in
                guard let month: Int = row["month"], let category: String = row["category"] else { return nil }
                return BudgetAnalysisBudgetEntry(month: month, categoryId: category, amountCents: row["amount"] ?? 0)
            }
            return ReportBudgetData(entries: entries, isTracking: table == "reflect_budgets")
        }
    }

    /// Per-month tracking-budget totals for the balance-forecast engine
    /// (upstream forecast-tracking-budget.ts: income = budgeted amounts across
    /// income categories, expenses = across the rest). Always reads
    /// reflect_budgets; callers gate on the budget type.
    func fetchTrackingBudgetMonths() async throws -> [BalanceForecastBudgetMonth] {
        try await dbQueue.read { db in
            guard try db.tableExists("reflect_budgets") else { return [] }
            let rows = try Row.fetchAll(db, sql: """
                SELECT b.month AS month,
                       SUM(CASE WHEN c.is_income = 1 THEN b.amount ELSE 0 END) AS income,
                       SUM(CASE WHEN c.is_income = 1 THEN 0 ELSE b.amount END) AS expenses
                FROM reflect_budgets b
                LEFT JOIN category_mapping cm ON cm.id = b.category
                LEFT JOIN categories c ON c.id = COALESCE(cm.transferId, b.category)
                WHERE b.category IS NOT NULL
                GROUP BY b.month
                """)
            return rows.compactMap { row in
                guard let month: Int = row["month"] else { return nil }
                return BalanceForecastBudgetMonth(
                    month: month,
                    budgetedIncomeCents: row["income"] ?? 0,
                    budgetedExpensesCents: row["expenses"] ?? 0
                )
            }
        }
    }

    func fetchFirstDayOfWeekIdx() async throws -> Int {
        try await dbQueue.read { db in
            guard try db.tableExists("preferences") else { return 0 }
            let value = try String.fetchOne(
                db, sql: "SELECT value FROM preferences WHERE id = 'firstDayOfWeekIdx'")
            return value.flatMap(Int.init) ?? 0
        }
    }

    // MARK: - CRDT Messages

    /// Inserts messages into messages_crdt and returns the subset that was
    /// actually new. The merkle trie hashes with XOR (self-inverse), so callers
    /// must only merkle-insert the returned messages — re-inserting an existing
    /// timestamp would cancel it back out of the trie.
    func insertMessages(_ messages: [CRDTMessage]) throws -> [CRDTMessage] {
        try dbQueue.write { db in
            try Self.insertMessageRows(db, messages)
        }
    }

    /// CRDT messages are uniquely identified by their HLC timestamp.
    /// The server can echo back messages we already have (e.g. ones we sent
    /// up on a previous sync), so a plain INSERT would hit a UNIQUE
    /// constraint and abort the batch. INSERT OR IGNORE is correct here —
    /// a duplicate timestamp means the same operation, so silently skipping
    /// is the convergent outcome.
    private static func insertMessageRows(_ db: Database, _ messages: [CRDTMessage]) throws -> [CRDTMessage] {
        var inserted: [CRDTMessage] = []
        for msg in messages {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO messages_crdt (timestamp, dataset, row, column, value)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    msg.timestamp.toString(),
                    msg.dataset,
                    msg.row,
                    msg.column,
                    msg.value
                ]
            )
            if db.changesCount > 0 {
                inserted.append(msg)
            }
        }
        return inserted
    }

    func getMaxMessageTimestamp() throws -> String? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT MAX(timestamp) AS ts FROM messages_crdt")?["ts"]
        }
    }

    /// Rebuild the sync merkle from `messages_crdt`.
    ///
    /// The trie is nothing but the XOR of every stored message's timestamp hash,
    /// so the message log — not the tree cached in `messages_clock` — is its
    /// source of truth. Re-deriving lets a persisted tree that drifted from the
    /// log be repaired instead of quietly misreporting parity with the server
    /// (see `SyncClient.fullSync`).
    ///
    /// A long-lived budget's log runs to hundreds of thousands of rows, so this
    /// avoids `HLCTimestamp` entirely: it hashes each stored timestamp string
    /// directly (`HLCTimestamp.hash()` murmurs `toString()`, which is exactly
    /// the text the log holds) and reads the trie's minute off the ISO-8601
    /// prefix arithmetically.
    func deriveMerkleFromMessageLog() throws -> MerkleTree {
        try dbQueue.read { db in
            guard try db.tableExists("messages_crdt") else { return MerkleTree() }

            var buckets: [Int64: Int32] = [:]
            let cursor = try String.fetchCursor(db, sql: "SELECT timestamp FROM messages_crdt")
            while let timestamp = try cursor.next() {
                guard let minutes = HLCTimestamp.minutesSinceEpoch(of: timestamp) else { continue }
                buckets[minutes * 60_000, default: 0] ^= Int32(bitPattern: MurmurHash3.hash(timestamp))
            }
            return MerkleTree.building(from: buckets).pruned()
        }
    }

    func getMessagesSince(_ since: String) throws -> [CRDTMessage] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT timestamp, dataset, row, column, value
                FROM messages_crdt
                WHERE timestamp > ?
                ORDER BY timestamp
                """, arguments: [since])

            return rows.compactMap { row -> CRDTMessage? in
                guard let timestampStr: String = row["timestamp"],
                      let timestamp = HLCTimestamp.parse(timestampStr) else {
                    return nil
                }

                return CRDTMessage(
                    timestamp: timestamp,
                    dataset: row["dataset"] ?? "",
                    row: row["row"] ?? "",
                    column: row["column"] ?? "",
                    value: row["value"] ?? ""
                )
            }
        }
    }

    /// Compare incoming messages with existing, filtering out already-applied ones
    func filterNewMessages(_ messages: [CRDTMessage]) throws -> [CRDTMessage] {
        try dbQueue.read { db in
            var newMessages: [CRDTMessage] = []

            for msg in messages {
                let existing = try Row.fetchOne(db, sql: """
                    SELECT timestamp FROM messages_crdt
                    WHERE dataset = ? AND row = ? AND column = ? AND timestamp >= ?
                    """, arguments: [
                        msg.dataset,
                        msg.row,
                        msg.column,
                        msg.timestamp.toString()
                    ])

                if existing == nil {
                    newMessages.append(msg)
                }
            }

            return newMessages
        }
    }

    /// Apply CRDT messages to the database.
    ///
    /// dataset/column are server-controlled identifiers, so they are validated
    /// against the live SQLite schema before being interpolated into SQL, and
    /// quoted as a second layer of defense. Messages are applied in timestamp
    /// order so the outcome doesn't depend on the order the server sent them.
    func applyMessages(_ messages: [CRDTMessage]) throws {
        try dbQueue.write { db in
            let schema = try Self.syncableSchema(db)

            for msg in messages.sorted(by: { $0.timestamp < $1.timestamp }) {
                // Unknown identifiers are either upstream schema we don't have
                // yet or a hostile server. Skip the message but let sync
                // continue: insertMessages still records it in messages_crdt so
                // a later schema migration can replay it.
                guard let columns = schema[msg.dataset], columns.contains(msg.column) else {
                    logger.warning(
                        "Skipping CRDT message for unknown schema \(msg.dataset, privacy: .public).\(msg.column, privacy: .public)"
                    )
                    continue
                }

                try Self.upsertValue(
                    db,
                    table: Self.quotedIdentifier(msg.dataset),
                    column: Self.quotedIdentifier(msg.column),
                    rowId: msg.row,
                    value: CRDTValue.deserialize(msg.value)
                )
            }
        }
    }

    /// Write one CRDT cell: update the row if it exists, otherwise create it
    /// with just the id and this column. `table`/`column` must already be
    /// schema-validated and quoted by the caller.
    private static func upsertValue(
        _ db: Database,
        table: String,
        column: String,
        rowId: String,
        value: DatabaseValue
    ) throws {
        let exists = try Row.fetchOne(db, sql: """
            SELECT id FROM \(table) WHERE id = ?
            """, arguments: [rowId]) != nil

        if exists {
            try db.execute(
                sql: "UPDATE \(table) SET \(column) = ? WHERE id = ?",
                arguments: [value, rowId]
            )
        } else {
            try db.execute(
                sql: "INSERT INTO \(table) (id, \(column)) VALUES (?, ?)",
                arguments: [rowId, value]
            )
        }
    }

    /// Table -> columns whitelist for CRDT applies, derived from the live
    /// SQLite schema (computed once per batch, not per message). Internal
    /// bookkeeping tables are never valid sync targets, and a table must have
    /// an `id` column for the row-based apply to make sense.
    private static func syncableSchema(_ db: Database) throws -> [String: Set<String>] {
        let internalTables: Set<String> = ["messages_crdt", "messages_clock", "migrations", "__migrations__"]
        var schema: [String: Set<String>] = [:]
        let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        for table in tables where !internalTables.contains(table) && !table.hasPrefix("sqlite_") {
            let columns = Set(try db.columns(in: table).map(\.name))
            if columns.contains("id") {
                schema[table] = columns
            }
        }
        return schema
    }

    private static func quotedIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Transaction Insert

    func insertTransaction(_ transaction: Transaction) throws {
        try dbQueue.write { db in
            try Self.insertTransactionRow(db, transaction)
        }
    }

    /// Inserts a newly-created account, its transfer payee (plus the payee's
    /// self-mapping row the transaction joins need), and its opening-balance
    /// transaction (if any) in a single SQLite transaction, so a failure on
    /// any row rolls back everything — mirrors `insertTransfer`'s
    /// all-or-nothing shape.
    func insertAccount(
        _ account: Account,
        transferPayee: Payee,
        startingBalanceTransaction: Transaction?
    ) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO accounts (id, name, type, offbudget, closed, tombstone, sort_order)
                VALUES (?, ?, ?, ?, ?, 0, ?)
                """, arguments: [
                    account.id,
                    account.name,
                    account.type.rawValue,
                    account.offBudget ? 1 : 0,
                    account.closed ? 1 : 0,
                    account.sortOrder
                ])
            try db.execute(sql: """
                INSERT INTO payees (id, name, transfer_acct, tombstone)
                VALUES (?, ?, ?, ?)
                """, arguments: [
                    transferPayee.id,
                    transferPayee.name,
                    transferPayee.transferAccountId,
                    transferPayee.tombstone ? 1 : 0
                ])
            try db.execute(sql: """
                INSERT INTO payee_mapping (id, targetId)
                VALUES (?, ?)
                """, arguments: [
                    transferPayee.id,
                    transferPayee.id
                ])
            if let startingBalanceTransaction {
                try Self.insertTransactionRow(db, startingBalanceTransaction)
            }
        }
    }

    /// Inserts both legs of a transfer and their CRDT messages in a single
    /// SQLite transaction, so a failure on either leg rolls back everything
    /// and no orphaned half-transfer can persist.
    /// Returns the subset of messages that was actually new (see `insertMessages`).
    func insertTransfer(
        source: Transaction,
        target: Transaction,
        messages: [CRDTMessage]
    ) throws -> [CRDTMessage] {
        try dbQueue.write { db in
            try Self.insertTransactionRow(db, source)
            try Self.insertTransactionRow(db, target)
            return try Self.insertMessageRows(db, messages)
        }
    }

    /// Repoints an existing transaction at a new partner leg and inserts that
    /// leg, with both rows' CRDT messages, in a single SQLite transaction —
    /// a partial write would leave the edited row's `transferred_id` pointing
    /// at a partner that was never created.
    /// Returns the subset of messages that was actually new (see `insertMessages`).
    func convertToTransfer(
        leg: Transaction,
        partner: Transaction,
        messages: [CRDTMessage]
    ) throws -> [CRDTMessage] {
        try dbQueue.write { db in
            try Self.updateTransactionRow(db, leg)
            try Self.insertTransactionRow(db, partner)
            return try Self.insertMessageRows(db, messages)
        }
    }

    /// Inserts a split parent, its children and their CRDT messages in a
    /// single SQLite transaction, so a failure on any row rolls back
    /// everything and no partial split can persist.
    /// Returns the subset of messages that was actually new (see `insertMessages`).
    func insertSplit(
        parent: Transaction,
        children: [Transaction],
        messages: [CRDTMessage]
    ) throws -> [CRDTMessage] {
        try dbQueue.write { db in
            try Self.insertTransactionRow(db, parent)
            for child in children {
                try Self.insertTransactionRow(db, child)
            }
            return try Self.insertMessageRows(db, messages)
        }
    }

    private static func insertTransactionRow(_ db: Database, _ transaction: Transaction) throws {
        // sort_order defaults to the current timestamp (ms) so new
        // transactions appear at the top; split rows pass explicit values so
        // children keep their entry order under the parent.
        let sortOrder = transaction.sortOrder ?? Date().timeIntervalSince1970 * 1000
        try db.execute(sql: """
            INSERT INTO transactions (id, acct, date, description, category, amount, notes, cleared, reconciled, transferred_id, isParent, isChild, parent_id, tombstone, sort_order, imported_description, schedule, financial_id, starting_balance_flag)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                transaction.id,
                transaction.accountId,
                transaction.date,
                transaction.payeeId,
                transaction.categoryId,
                transaction.amount,
                transaction.notes,
                transaction.cleared ? 1 : 0,
                transaction.reconciled ? 1 : 0,
                transaction.transferId,
                transaction.isParent ? 1 : 0,
                transaction.parentId != nil ? 1 : 0,
                transaction.parentId,
                transaction.tombstone ? 1 : 0,
                sortOrder,
                transaction.importedPayee,
                transaction.schedule,
                transaction.financialId,
                transaction.startingBalanceFlag ? 1 : 0
            ])
    }

    /// All bank-import dedup keys (`financial_id`) already present on an
    /// account. Tombstoned rows are deliberately included: a user who deleted
    /// an imported transaction shouldn't see it resurrected by a re-import.
    func existingFinancialIds(accountId: String) throws -> Set<String> {
        try dbQueue.read { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT financial_id FROM transactions
                WHERE acct = ? AND financial_id IS NOT NULL
                """, arguments: [accountId])
            return Set(ids)
        }
    }

    // MARK: - Transaction Update

    /// Update an existing transaction's columns in place.
    /// Caller is responsible for emitting CRDT messages for the same fields.
    func updateTransaction(_ transaction: Transaction) throws {
        try dbQueue.write { db in
            try Self.updateTransactionRow(db, transaction)
        }
    }

    private static func updateTransactionRow(_ db: Database, _ transaction: Transaction) throws {
        try db.execute(sql: """
            UPDATE transactions
            SET acct = ?, date = ?, description = ?, category = ?, amount = ?,
                notes = ?, cleared = ?, reconciled = ?, transferred_id = ?,
                isParent = ?, parent_id = ?, tombstone = ?
            WHERE id = ?
            """, arguments: [
                transaction.accountId,
                transaction.date,
                transaction.payeeId,
                transaction.categoryId,
                transaction.amount,
                transaction.notes,
                transaction.cleared ? 1 : 0,
                transaction.reconciled ? 1 : 0,
                transaction.transferId,
                transaction.isParent ? 1 : 0,
                transaction.parentId,
                transaction.tombstone ? 1 : 0,
                transaction.id
            ])
    }

    // MARK: - Rules

    func rulesTableExists() throws -> Bool {
        try dbQueue.read { db in try db.tableExists("rules") }
    }
    
    /// Budget-level context the rules engine needs for conditions it can't
    /// answer from the transaction row (upstream `prepareTransactionForRules`).
    func ruleContext() throws -> RuleContext {
        try dbQueue.read { db in
            let offBudget = try Set(String.fetchAll(
                db, sql: "SELECT id FROM accounts WHERE offbudget = 1"
            ))

            var groups: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT id, cat_group FROM categories
                WHERE tombstone = 0 OR tombstone IS NULL
                """) {
                if let id: String = row["id"], let group: String = row["cat_group"] {
                    groups[id] = group
                }
            }

            var payeeNames: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT id, name FROM payees
                WHERE tombstone = 0 OR tombstone IS NULL
                """) {
                if let id: String = row["id"], let name: String = row["name"] {
                    payeeNames[id] = name
                }
            }

            return RuleContext(
                offBudgetAccountIds: offBudget,
                categoryGroupIds: groups,
                payeeNames: payeeNames
            )
        }
    }

    /// The live payee with this name, case-insensitively — how a `payee_name`
    /// action resolves to an id before we fall back to creating one.
    func payee(named name: String) throws -> Payee? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT id, name, transfer_acct FROM payees
                WHERE (tombstone = 0 OR tombstone IS NULL) AND name = ? COLLATE NOCASE
                LIMIT 1
                """, arguments: [name])
            guard let row, let id: String = row["id"] else { return nil }
            return Payee(id: id, name: row["name"] ?? name, transferAccountId: row["transfer_acct"])
        }
    }

    /// All live rules. Returns [] when the budget file has no `rules` table.
    func fetchRules() throws -> [Rule] {
        try dbQueue.read { db in try Self.liveRules(db) }
    }

    /// Live rules in the order the engine runs them — what the Rules screen shows,
    /// matching upstream's `rules-get` (which returns `rankRules(...)`).
    func fetchRulesRanked() async throws -> [Rule] {
        try await dbQueue.read { db in RuleRanker.rank(try Self.liveRules(db)) }
    }

    private static func liveRules(_ db: Database) throws -> [Rule] {
        guard try db.tableExists("rules") else { return [] }

        let rows = try Row.fetchAll(db, sql: """
            SELECT id, stage, conditions_op, conditions, actions
            FROM rules
            WHERE tombstone = 0 OR tombstone IS NULL
            """)

        return rows.compactMap { row in
            guard let id: String = row["id"] else { return nil }
            // A rule we can't parse is a rule we must not silently half-apply:
            // upstream drops invalid rules on load too (`makeRule` returns null).
            return try? Rule.parse(
                id: id,
                stage: row["stage"],
                conditionsOp: row["conditions_op"],
                conditionsJSON: row["conditions"],
                actionsJSON: row["actions"]
            )
        }
    }

    /// Rule ids a schedule owns. Upstream refuses to delete these
    /// (`deleteRule` returns false when a schedule points at the rule), and the
    /// list badges them so it's clear why.
    func scheduleOwnedRuleIds() throws -> Set<String> {
        try dbQueue.read { db in
            guard try db.tableExists("schedules") else { return [] }
            return try Set(String.fetchAll(db, sql: """
                SELECT rule FROM schedules
                WHERE rule IS NOT NULL AND (tombstone = 0 OR tombstone IS NULL)
                """))
        }
    }

    // MARK: - Schedules

    /// Fetch schedules eligible for auto-posting: alive, not completed, and
    /// flagged `posts_transaction = 1`, with their rule conditions extracted
    /// (port of loot-core `extractScheduleConds`). The poster writes to users'
    /// real servers, so doubt about WHAT to post (conditions, account, next
    /// date) is a logged skip — never a throw. Doubt about the recurrence
    /// alone is `.unsupported`, not a skip: upstream posts the stored due
    /// occurrence either way and only its advance fails. Returns [] when the
    /// schedule tables don't exist (older budget files).
    func fetchPostableSchedules() throws -> [Schedule] {
        try dbQueue.read { db in try Self.schedules(db, postableOnly: true) }
    }

    /// Schedules for the balance-forecast engine: same parsing as the poster,
    /// but manual (posts_transaction = 0) schedules forecast too, matching
    /// upstream forecast-schedules.ts.
    func fetchForecastSchedules() async throws -> [Schedule] {
        try await dbQueue.read { db in try Self.schedules(db, postableOnly: false) }
    }

    private static func schedules(_ db: Database, postableOnly: Bool) throws -> [Schedule] {
            guard try db.tableExists("schedules"),
                  try db.tableExists("schedules_next_date"),
                  try db.tableExists("rules")
            else { return [] }

            let closedAccounts = try Set(String.fetchAll(
                db, sql: "SELECT id FROM accounts WHERE closed = 1"
            ))

            let rows = try Row.fetchAll(db, sql: """
                SELECT s.id, s.name, nd.id AS nd_id,
                       nd.local_next_date, nd.local_next_date_ts,
                       nd.base_next_date, nd.base_next_date_ts,
                       r.conditions, r.actions
                FROM schedules s
                JOIN schedules_next_date nd ON nd.schedule_id = s.id
                JOIN rules r ON r.id = s.rule
                WHERE (s.tombstone = 0 OR s.tombstone IS NULL)
                  AND (s.completed = 0 OR s.completed IS NULL)
                  AND (s.posts_transaction = 1 OR \(postableOnly ? 0 : 1))
                  AND (r.tombstone = 0 OR r.tombstone IS NULL)
                ORDER BY s.id, nd.id
                """)

            // A duplicated schedules_next_date row (bad sync) would otherwise
            // return the same schedule twice and the poster could double-post.
            // First row wins, deterministically via ORDER BY nd.id above.
            var seenScheduleIds = Set<String>()

            return try rows.compactMap { row -> Schedule? in
                guard let id: String = row["id"] else { return nil }

                guard seenScheduleIds.insert(id).inserted else {
                    logger.notice("Skipping duplicate schedules_next_date row for schedule \(id, privacy: .public)")
                    return nil
                }

                guard let nextDateRowId: String = row["nd_id"] else {
                    logger.notice("Skipping schedule \(id, privacy: .public): incomplete schedules_next_date row")
                    return nil
                }
                // NULL is postable: the web's v_schedules CASE falls through
                // to base_next_date for NULL timestamps, and its advance
                // writes local_next_date_ts = NULL — so must ours.
                let baseNextDateTs: Int64? = row["base_next_date_ts"]

                guard let conditions = Self.parseConditionsArray(row["conditions"]) else {
                    logger.notice("Skipping schedule \(id, privacy: .public): unparseable rule conditions")
                    return nil
                }

                // Account: required, and must be open.
                guard let accountId = Self.firstCondition(
                    in: conditions, ops: ["is"], fields: ["account", "acct"]
                )?["value"] as? String else {
                    logger.notice("Skipping schedule \(id, privacy: .public): no account condition")
                    return nil
                }
                guard !closedAccounts.contains(accountId) else {
                    logger.notice("Skipping schedule \(id, privacy: .public): account is closed")
                    return nil
                }

                // Date: informs only the ADVANCE. Upstream posting works off
                // the stored next_date regardless of this condition (its
                // setNextDate throws on unsupported shapes after posting and
                // the service swallows it), so a missing or unparseable date
                // condition still posts — once, without advancing.
                let dateCondition = Self.parseDateCondition(in: conditions)
                if case .unsupported = dateCondition {
                    logger.notice("Schedule \(id, privacy: .public): date condition missing or unsupported - due occurrence will post without advancing")
                }

                // Effective next date, per loot-core's v_schedules view:
                // local_next_date when local_next_date_ts = base_next_date_ts,
                // else base_next_date (NULL timestamps fall through to base,
                // matching SQL NULL-comparison semantics).
                let localTs: Int64? = row["local_next_date_ts"]
                let effectiveRaw: Int? = (localTs != nil && localTs == baseNextDateTs)
                    ? row["local_next_date"]
                    : row["base_next_date"]
                guard let effectiveRaw, let nextDate = DayDate(yyyymmdd: effectiveRaw) else {
                    logger.notice("Skipping schedule \(id, privacy: .public): missing or invalid next date")
                    return nil
                }

                // Payee: optional. loot-core's v_schedules resolves the raw
                // condition value through payee_mapping (pm.targetId, LEFT
                // JOIN), so an unmapped payee yields nil there too.
                var payeeId: String?
                if let rawPayee = Self.firstCondition(
                    in: conditions, ops: ["is"], fields: ["payee", "description"]
                )?["value"] as? String {
                    payeeId = try String.fetchOne(
                        db, sql: "SELECT targetId FROM payee_mapping WHERE id = ?",
                        arguments: [rawPayee]
                    )
                }

                return Schedule(
                    id: id,
                    name: row["name"],
                    nextDate: nextDate,
                    nextDateRowId: nextDateRowId,
                    baseNextDateTs: baseNextDateTs,
                    accountId: accountId,
                    payeeId: payeeId,
                    categoryId: Self.parseCategoryAction(row["actions"]),
                    amount: Self.parseAmountCondition(in: conditions, scheduleId: id),
                    dateCondition: dateCondition
                )
            }
    }
    
    /// Every live schedule, for the schedules screen — including completed and
    /// manual ones, which `fetchPostableSchedules` deliberately excludes.
    ///
    /// Unlike the poster's fetch, the rule and next-date joins are LEFT joins.
    /// The poster is right to skip a schedule it can't fully understand; the
    /// list is not — a schedule whose rule or next-date row went missing must
    /// still appear so it can be fixed or deleted, rather than becoming an
    /// invisible row only the web app can reach.
    func fetchSchedules() async throws -> [ScheduleSummary] {
        try await dbQueue.read { db in
            guard try db.tableExists("schedules"),
                  try db.tableExists("schedules_next_date"),
                  try db.tableExists("rules")
            else { return [] }

            let rows = try Row.fetchAll(db, sql: """
                SELECT s.*,
                       nd.id AS nd_id,
                       nd.local_next_date, nd.local_next_date_ts,
                       nd.base_next_date, nd.base_next_date_ts,
                       r.id AS rule_id, r.conditions, r.actions
                FROM schedules s
                LEFT JOIN schedules_next_date nd ON nd.schedule_id = s.id
                LEFT JOIN rules r ON r.id = s.rule
                    AND (r.tombstone = 0 OR r.tombstone IS NULL)
                WHERE (s.tombstone = 0 OR s.tombstone IS NULL)
                ORDER BY s.id, nd.id
                """)

            // A duplicated schedules_next_date row (bad sync) would list the
            // same schedule twice. First row wins, deterministically via the
            // ORDER BY above — same rule the poster uses.
            var seen = Set<String>()

            return try rows.compactMap { row -> ScheduleSummary? in
                guard let id: String = row["id"], seen.insert(id).inserted else { return nil }

                let conditions = Self.parseConditionsArray(row["conditions"]) ?? []
                let actions = Self.parseConditionsArray(row["actions"]) ?? []

                let accountCond = Self.firstCondition(
                    in: conditions, ops: ["is"], fields: ["account", "acct"])
                let payeeCond = Self.firstCondition(
                    in: conditions, ops: ["is"], fields: ["payee", "description"])
                let amountCond = Self.firstCondition(
                    in: conditions, ops: ["is", "isapprox", "isbetween"], fields: ["amount"])
                let dateCond = Self.firstCondition(
                    in: conditions, ops: ["is", "isapprox"], fields: ["date"])

                // Effective next date, per loot-core's v_schedules view:
                // local when the timestamps agree, else base.
                let localTs: Int64? = row["local_next_date_ts"]
                let baseTs: Int64? = row["base_next_date_ts"]
                let effectiveRaw: Int? = (localTs != nil && localTs == baseTs)
                    ? row["local_next_date"]
                    : row["base_next_date"]

                // Payee ids resolve through payee_mapping, so a merged payee
                // reads as its surviving target — same as the v_schedules
                // LEFT JOIN.
                var payeeId = payeeCond?["value"] as? String
                if let raw = payeeId {
                    payeeId = try String.fetchOne(
                        db,
                        sql: "SELECT targetId FROM payee_mapping WHERE id = ?",
                        arguments: [raw])
                }

                // "Custom" = the rule says more than the four conditions a
                // schedule owns, or does something other than link itself.
                let recognised = [accountCond, payeeCond, amountCond, dateCond]
                    .compactMap { $0 }.count
                let isCustom = conditions.count > recognised
                    || actions.contains { ($0["op"] as? String) != "link-schedule" }

                return ScheduleSummary(
                    id: id,
                    name: row["name"],
                    ruleId: row["rule_id"],
                    nextDate: effectiveRaw.flatMap { DayDate(yyyymmdd: $0) },
                    nextDateRowId: row["nd_id"],
                    baseNextDateTs: baseTs,
                    accountId: accountCond?["value"] as? String,
                    payeeId: payeeId,
                    amount: Self.parseAmountCondition(in: conditions, scheduleId: id),
                    amountOp: (amountCond?["op"] as? String)
                        .flatMap(ScheduleAmountOp.init(rawValue:)) ?? .isApprox,
                    dateOp: dateCond?["op"] as? String,
                    dateCondition: Self.parseDateCondition(in: conditions),
                    postsTransaction: row["posts_transaction"] == 1,
                    completed: row["completed"] == 1,
                    customUpcomingLength: row["custom_upcoming_length"],
                    sortOrder: row["sort_order"],
                    isCustom: isCustom,
                    conditionsJSON: row["conditions"],
                    actionsJSON: row["actions"],
                    categoryId: Self.parseCategoryAction(row["actions"])
                )
            }
        }
    }

    /// Schedules that already have a transaction covering their current
    /// occurrence — the `paid` input to the status calculator. Port of
    /// loot-core `getHasTransactionsQuery`, collapsed into one grouped query
    /// rather than a large OR: each schedule's own lower bound is applied in
    /// Swift against the latest linked transaction date.
    func fetchPaidScheduleIds(for schedules: [ScheduleSummary]) async throws -> Set<String> {
        let bounds: [(id: String, start: Int)] = schedules.compactMap { schedule in
            guard let nextDate = schedule.nextDate else { return nil }
            let start = ScheduleStatusCalculator.occurrenceMatchStartDate(
                nextDate: nextDate,
                dateOp: schedule.dateOp,
                postsTransaction: schedule.postsTransaction)
            return (schedule.id, start.yyyymmdd)
        }
        guard !bounds.isEmpty else { return [] }

        return try await dbQueue.read { db in
            let placeholders = Array(repeating: "?", count: bounds.count).joined(separator: ", ")
            let rows = try Row.fetchAll(db, sql: """
                SELECT schedule, MAX(date) AS max_date
                FROM transactions
                WHERE schedule IN (\(placeholders))
                  AND (tombstone = 0 OR tombstone IS NULL)
                GROUP BY schedule
                """, arguments: StatementArguments(bounds.map(\.id)))

            var latestDate: [String: Int] = [:]
            for row in rows {
                guard let scheduleId: String = row["schedule"],
                      let maxDate: Int = row["max_date"] else { continue }
                latestDate[scheduleId] = maxDate
            }

            var paid = Set<String>()
            for bound in bounds where (latestDate[bound.id] ?? Int.min) >= bound.start {
                paid.insert(bound.id)
            }
            return paid
        }
    }
    
    /// Is another live schedule already using this name? Mirrors loot-core
    /// `checkIfScheduleExists`, which enforces unique names so the "link to
    /// schedule" pickers stay unambiguous.
    func scheduleNameExists(_ name: String, excluding scheduleId: String?) throws -> Bool {
        try dbQueue.read { db in
            let existingId = try String.fetchOne(db, sql: """
                SELECT id FROM schedules
                WHERE (tombstone = 0 OR tombstone IS NULL)
                  AND name = ?
                  AND (? IS NULL OR id <> ?)
                LIMIT 1
                """, arguments: [name, scheduleId, scheduleId])
            return existingId != nil
        }
    }

    /// Refresh the local `schedules_json_paths` cache for one schedule.
    ///
    /// This table is NOT synced — loot-core rebuilds it locally from a sync
    /// listener whenever a rule changes, so the web repairs its own copy when
    /// our rule arrives. Actuali doesn't read the table at all (it parses rule
    /// conditions directly), but keeping the local file self-consistent costs
    /// one statement and means nothing depends on a listener we don't run.
    ///
    /// It also has no `id` column, so it could not go through the CRDT apply
    /// path even if it were synced.
    func writeScheduleJSONPaths(scheduleId: String, conditions: [[String: Any]]) throws {
        try dbQueue.write { db in
            guard try db.tableExists("schedules_json_paths") else { return }
            let paths = ScheduleConditions.jsonPaths(for: conditions)
            try db.execute(sql: """
                INSERT OR REPLACE INTO schedules_json_paths
                    (schedule_id, payee, account, amount, date)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [scheduleId, paths.payee, paths.account,
                                 paths.amount, paths.date])
        }
    }

    /// Dedup guard for the poster: does an alive transaction linked to this
    /// schedule already exist on/after `date` (YYYYMMDD int)?
    func hasTransaction(scheduleId: String, onOrAfter date: Int) throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM transactions
                    WHERE schedule = ? AND date >= ?
                      AND (tombstone = 0 OR tombstone IS NULL)
                )
                """, arguments: [scheduleId, date]) ?? false
        }
    }

    private static func parseConditionsArray(_ json: String?) -> [[String: Any]]? {
        guard let json, let data = json.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return any as? [[String: Any]]
    }

    /// loot-core `extractScheduleConds` lookup: fields are tried in order
    /// (e.g. a `payee` condition wins over an earlier `description` one),
    /// first array match wins within a field.
    private static func firstCondition(
        in conditions: [[String: Any]], ops: Set<String>, fields: [String]
    ) -> [String: Any]? {
        for field in fields {
            if let match = conditions.first(where: {
                ($0["op"] as? String).map(ops.contains) == true && $0["field"] as? String == field
            }) {
                return match
            }
        }
        return nil
    }

    /// The linked rule's `set category` action, when present. loot-core
    /// applies it through runRules at post time; the iOS RulesEngine can't
    /// match the rule's recurring-date condition (see Rule.swift), so the
    /// category is surfaced here for the poster to set directly. Malformed
    /// actions yield nil — an uncategorized post, never a skipped schedule.
    private static func parseCategoryAction(_ json: String?) -> String? {
        guard let actions = parseConditionsArray(json) else { return nil }
        return firstCondition(in: actions, ops: ["set"], fields: ["category"])?["value"] as? String
    }

    private static func parseAmountCondition(
        in conditions: [[String: Any]], scheduleId: String
    ) -> ScheduledAmount? {
        guard let cond = firstCondition(
            in: conditions, ops: ["is", "isapprox", "isbetween"], fields: ["amount"]
        ) else { return nil }
        if let number = cond["value"] as? NSNumber {
            return .fixed(number.intValue)
        }
        if let range = cond["value"] as? [String: Any],
           let num1 = range["num1"] as? NSNumber, let num2 = range["num2"] as? NSNumber {
            return .range(num1.intValue, num2.intValue)
        }
        // Distinguish "amount condition present but malformed" from "no
        // amount condition" — both yield nil, but only this one is a surprise.
        logger.notice("Schedule \(scheduleId, privacy: .public): amount condition has unrecognized value shape, treating as no amount")
        return nil
    }

    private static func parseDateCondition(in conditions: [[String: Any]]) -> ScheduleDateCondition {
        guard let cond = firstCondition(
            in: conditions, ops: ["is", "isapprox"], fields: ["date"]
        ) else { return .unsupported }
        // Fixed dates inside conditions JSON are "YYYY-MM-DD" strings
        // (unlike the schedules_next_date columns, which are YYYYMMDD ints).
        if let iso = cond["value"] as? String, let day = DayDate(iso: iso) {
            return .fixed(day)
        }
        if let recur = cond["value"] as? [String: Any], let config = RecurConfig(json: recur) {
            return .recurring(config)
        }
        return .unsupported
    }
    
    /// Transactions linked to a schedule, newest first. Powers the editor's
    /// linked-transactions section and the unlink action.
    func fetchTransactions(scheduleId: String, limit: Int = 50) throws -> [Transaction] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.id, t.isParent, t.isChild, t.acct, t.category, t.amount,
                       t.description, t.notes, t.date, t.imported_description,
                       t.schedule, t.transferred_id, t.cleared, t.reconciled,
                       t.sort_order, t.tombstone, t.parent_id,
                       COALESCE(pa.name, p.name) AS payee_name,
                       c.name AS category_name
                FROM transactions t
                LEFT JOIN payee_mapping pm ON pm.id = t.description
                LEFT JOIN payees p ON p.id = pm.targetId
                LEFT JOIN payees pa ON pa.id = t.description
                LEFT JOIN categories c ON c.id = t.category
                WHERE t.schedule = ?
                  AND (t.tombstone = 0 OR t.tombstone IS NULL)
                  AND t.date IS NOT NULL
                  AND t.acct IS NOT NULL
                ORDER BY t.date DESC, t.sort_order DESC
                LIMIT ?
                """, arguments: [scheduleId, limit])
            return rows.map(Self.mapTransaction)
        }
    }
    
    /// Set or clear the schedule link on transactions.
    ///
    /// Deliberately narrow rather than adding `schedule` to `updateTransaction`:
    /// the transaction editor rebuilds its row without carrying that column, so
    /// widening the shared UPDATE would clear the link whenever a scheduled
    /// transaction is edited by hand.
    func setTransactionSchedule(transactionIds: [String], scheduleId: String?) throws {
        guard !transactionIds.isEmpty else { return }
        try dbQueue.write { db in
            let placeholders = Array(repeating: "?", count: transactionIds.count).joined(separator: ", ")
            var arguments: [DatabaseValueConvertible?] = [scheduleId]
            arguments.append(contentsOf: transactionIds)
            try db.execute(
                sql: "UPDATE transactions SET schedule = ? WHERE id IN (\(placeholders))",
                arguments: StatementArguments(arguments))
        }
    }
    
    /// One account's transactions that are eligible to form a schedule.
    ///
    /// Mirrors the filters in upstream's `getTransactions`: already-scheduled
    /// rows are excluded, transfers are excluded (they pair two accounts and
    /// aren't a bill), and split children are excluded so a split doesn't read
    /// as several independent payments.
    func fetchDiscoveryTransactions(
        accountId: String,
        notBefore: Int
    ) throws -> [ScheduleDiscovery.Candidate] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.id, t.date, t.amount, pm.targetId AS payee_id
                FROM transactions t
                JOIN payee_mapping pm ON pm.id = t.description
                LEFT JOIN payees p ON p.id = pm.targetId
                WHERE t.acct = ?
                  AND t.date >= ?
                  AND (t.tombstone = 0 OR t.tombstone IS NULL)
                  AND t.schedule IS NULL
                  AND (t.isChild = 0 OR t.isChild IS NULL)
                  AND t.transferred_id IS NULL
                  AND p.transfer_acct IS NULL
                ORDER BY t.date ASC
                """, arguments: [accountId, notBefore])

            return rows.compactMap { row in
                guard let id: String = row["id"],
                      let rawDate: Int = row["date"],
                      let date = DayDate(yyyymmdd: rawDate),
                      let payeeId: String = row["payee_id"],
                      let amount: Int = row["amount"]
                else { return nil }
                return ScheduleDiscovery.Candidate(
                    id: id, date: date, amount: amount,
                    payeeId: payeeId, accountId: accountId)
            }
        }
    }

    /// Latest transaction date on an account — the anchor every pattern sweep
    /// measures back from.
    func latestTransactionDate(accountId: String) throws -> DayDate? {
        try dbQueue.read { db in
            let raw = try Int.fetchOne(db, sql: """
                SELECT date FROM transactions
                WHERE acct = ? AND (tombstone = 0 OR tombstone IS NULL)
                  AND parent_id IS NULL
                ORDER BY date DESC LIMIT 1
                """, arguments: [accountId])
            return raw.flatMap { DayDate(yyyymmdd: $0) }
        }
    }

    // MARK: - Preferences

    /// Fetch currency code from preferences table (stored by Actual Budget)
    /// Returns nil if not set, caller should default to "USD"
    func fetchCurrencyCode() async throws -> String? {
        try await dbQueue.read { db in
            // Check if preferences table exists
            guard try db.tableExists("preferences") else {
                return nil
            }

            let row = try Row.fetchOne(db, sql: """
                SELECT value FROM preferences WHERE id = 'defaultCurrencyCode'
                """)

            return row?["value"]
        }
    }
    
    /// Budget-wide upcoming-schedule window, as stored by Actual. Nil when
    /// unset, so callers fall back to `ScheduleUpcomingLength.fallback`.
    func fetchUpcomingScheduledTransactionLength() async throws -> String? {
        try await dbQueue.read { db in
            guard try db.tableExists("preferences") else { return nil }
            let row = try Row.fetchOne(db, sql: """
                SELECT value FROM preferences
                WHERE id = 'upcomingScheduledTransactionLength'
                """)
            return row?["value"]
        }
    }

    // MARK: - Payee Insert

    func insertPayee(_ payee: Payee) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO payees (id, name, transfer_acct, tombstone)
                VALUES (?, ?, ?, ?)
                """, arguments: [
                    payee.id,
                    payee.name,
                    payee.transferAccountId,
                    payee.tombstone ? 1 : 0
                ])

            // Also insert into payee_mapping (required for transaction joins)
            try db.execute(sql: """
                INSERT INTO payee_mapping (id, targetId)
                VALUES (?, ?)
                """, arguments: [
                    payee.id,
                    payee.id
                ])
        }
    }

    // MARK: - Payee Locations

    func insertPayeeLocation(_ location: PayeeLocation) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO payee_locations (id, payee_id, latitude, longitude, created_at, tombstone)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                    location.id,
                    location.payeeId,
                    location.latitude,
                    location.longitude,
                    location.createdAt,
                    location.tombstone ? 1 : 0
                ])
        }
    }

    /// Soft-delete one recorded location (CRDT tombstone, matching upstream).
    func tombstonePayeeLocation(id: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE payee_locations SET tombstone = 1 WHERE id = ?",
                arguments: [id])
        }
    }

    /// Non-tombstoned locations for a payee, newest first (upstream
    /// getPayeeLocations ordering).
    func fetchPayeeLocations(payeeId: String) async throws -> [PayeeLocation] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, payee_id, latitude, longitude, created_at
                FROM payee_locations
                WHERE tombstone IS NOT 1 AND payee_id = ?
                  AND latitude IS NOT NULL AND longitude IS NOT NULL AND created_at IS NOT NULL
                ORDER BY created_at DESC
                """, arguments: [payeeId])
            return rows.map { row in
                PayeeLocation(
                    id: row["id"],
                    payeeId: row["payee_id"],
                    latitude: row["latitude"],
                    longitude: row["longitude"],
                    createdAt: row["created_at"]
                )
            }
        }
    }

    /// Every non-tombstoned payee that still has at least one non-tombstoned
    /// location, name-ordered, with its live location count — the top level of
    /// the Payee Locations screen. The NULL guards match
    /// `fetchPayeeLocations`, so a count never overstates what the detail
    /// screen can show.
    func fetchPayeesWithLocations() async throws -> [PayeeLocationSummary] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.id, p.name, p.transfer_acct, COUNT(pl.id) AS location_count
                FROM payees p
                JOIN payee_locations pl ON pl.payee_id = p.id
                WHERE p.tombstone IS NOT 1 AND pl.tombstone IS NOT 1
                  AND pl.latitude IS NOT NULL AND pl.longitude IS NOT NULL
                  AND pl.created_at IS NOT NULL
                GROUP BY p.id
                ORDER BY p.name COLLATE NOCASE ASC, p.id ASC
                """)
            return rows.map { row in
                PayeeLocationSummary(
                    payee: Payee(
                        id: row["id"],
                        name: row["name"] ?? "Unknown",
                        transferAccountId: row["transfer_acct"]
                    ),
                    locationCount: row["location_count"]
                )
            }
        }
    }

    /// Nearby payees: closest non-tombstoned location per non-tombstoned
    /// payee within `maxDistanceMeters`, ascending by distance, limit 10
    /// (upstream getNearbyPayees). Distance is computed in Swift because the
    /// system SQLite math functions (acos etc.) aren't guaranteed on iOS.
    func fetchNearbyPayees(
        latitude: Double,
        longitude: Double,
        maxDistanceMeters: Double = LocationUtils.defaultMaxDistanceMeters
    ) async throws -> [NearbyPayee] {
        guard LocationUtils.isValidCoordinate(latitude: latitude, longitude: longitude),
              maxDistanceMeters.isFinite, maxDistanceMeters > 0 else {
            return []
        }
        let rows: [Row] = try await dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT pl.id AS location_id, pl.payee_id, pl.latitude, pl.longitude, pl.created_at,
                       p.name, p.transfer_acct
                FROM payee_locations pl
                JOIN payees p ON p.id = pl.payee_id
                WHERE pl.tombstone IS NOT 1 AND p.tombstone IS NOT 1
                  AND pl.latitude IS NOT NULL AND pl.longitude IS NOT NULL AND pl.created_at IS NOT NULL
                """)
        }
        var closestByPayee: [String: NearbyPayee] = [:]
        for row in rows {
            let location = PayeeLocation(
                id: row["location_id"],
                payeeId: row["payee_id"],
                latitude: row["latitude"],
                longitude: row["longitude"],
                createdAt: row["created_at"]
            )
            let distance = LocationUtils.calculateDistanceMeters(
                lat1: latitude, lon1: longitude,
                lat2: location.latitude, lon2: location.longitude
            )
            guard distance <= maxDistanceMeters else { continue }
            if let existing = closestByPayee[location.payeeId],
               existing.distanceMeters <= distance {
                continue
            }
            let payee = Payee(
                id: location.payeeId,
                name: row["name"] ?? "Unknown",
                transferAccountId: row["transfer_acct"]
            )
            closestByPayee[location.payeeId] = NearbyPayee(
                payee: payee, location: location, distanceMeters: distance)
        }
        return closestByPayee.values
            .sorted {
                ($0.distanceMeters, $0.payee.id) < ($1.distanceMeters, $1.payee.id)
            }
            .prefix(10)
            .map { $0 }
    }
}
