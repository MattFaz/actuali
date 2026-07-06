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
        dbQueue = try DatabaseQueue(path: path.path)
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
        (1769000000000, "schedules", "custom_upcoming_length", [],
         "ALTER TABLE schedules ADD COLUMN custom_upcoming_length TEXT DEFAULT NULL"),
        // Upstream 1778510362740 also creates cleanup_groups (see createTableMigrations).
        (1778510362741, "categories", "cleanup_def", [],
         "ALTER TABLE categories ADD COLUMN cleanup_def TEXT DEFAULT NULL"),
        (1780099200000, "custom_reports", "show_trend_lines", [],
         "ALTER TABLE custom_reports ADD COLUMN show_trend_lines INTEGER DEFAULT 0"),
        (1780327681000, "tags", "hidden", [],
         "ALTER TABLE tags ADD COLUMN hidden BOOLEAN DEFAULT 0"),
        (1780606215000, "accounts", "bank_sync_status", [],
         "ALTER TABLE accounts ADD COLUMN bank_sync_status TEXT"),
        // Upstream ships both indexes as one migration (1780606215001); split
        // here so each waits for its own columns — old snapshots can lack
        // transactions.schedule.
        (1780606215001, "transactions", nil, ["acct", "tombstone"],
         "CREATE INDEX IF NOT EXISTS idx_transactions_acct_tombstone ON transactions(acct, tombstone)"),
        (1780606215002, "transactions", nil, ["schedule"],
         "CREATE INDEX IF NOT EXISTS idx_transactions_schedule ON transactions(schedule)")
    ]

    // Tables added upstream after the original budget file was created. These run
    // unconditionally so CRDT messages targeting these tables have somewhere to land.
    private static let createTableMigrations: [(id: Int64, sql: String)] = [
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

    private func runPendingMigrations() throws {
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
            // children whose parent is tombstoned: deleting a split tombstones
            // the parent but leaves the child rows with tombstone = 0, so a
            // per-row tombstone check alone would still count those orphans
            // (matching Actual's alive view). Transfer legs still count;
            // accounts with no transactions get 0.
            let balanceRows = try Row.fetchAll(db, sql: """
                SELECT t.acct AS acct, COALESCE(SUM(t.amount), 0) AS balance
                FROM transactions t
                LEFT JOIN transactions p ON p.id = t.parent_id
                WHERE t.acct IS NOT NULL
                  AND (t.tombstone = 0 OR t.tombstone IS NULL)
                  AND (t.parent_id IS NULL OR p.tombstone = 0 OR p.tombstone IS NULL)
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

    // MARK: - Transactions

    func fetchTransactions(accountId: String? = nil, limit: Int = 100) async throws -> [Transaction] {
        try await dbQueue.read { db in
            var sql = """
                SELECT
                    t.id, t.isParent, t.isChild, t.acct, t.category, t.amount,
                    t.description, t.notes, t.date, t.imported_description,
                    t.transferred_id, t.cleared, t.reconciled, t.sort_order,
                    t.tombstone, t.parent_id,
                    COALESCE(pa.name, p.name) as payee_name,
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
                WHERE (t.tombstone = 0 OR t.tombstone IS NULL)
                  AND (t.isChild = 0 OR t.isChild IS NULL)
                """

            var arguments: [String] = []

            if let accountId {
                sql += " AND t.acct = ?"
                arguments.append(accountId)
            }

            sql += " ORDER BY t.date DESC, t.sort_order DESC LIMIT ?"
            arguments.append(String(limit))

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
                    importedPayee: row["imported_description"]
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
          AND (t.isParent = 0 OR t.isParent IS NULL)
          AND (t.parent_id IS NULL OR par.tombstone = 0 OR par.tombstone IS NULL)
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
                    t.transferred_id, t.cleared, t.reconciled, t.sort_order,
                    t.tombstone, t.parent_id,
                    COALESCE(pa.name, p.name, ppa.name, pp.name) as payee_name
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
                    importedPayee: row["imported_description"]
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
                            sortOrder: Int(cat.sortOrder ?? 0)
                        )
                    }

                return CategoryGroup(
                    id: group.id,
                    name: group.name ?? "Unknown",
                    isIncome: group.isIncome == 1,
                    hidden: group.hidden == 1,
                    sortOrder: Int(group.sortOrder ?? 0),
                    categories: categories
                )
            }
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
            let hasZeroBudgets = try db.tableExists("zero_budgets")
            let hasReflectBudgets = try db.tableExists("reflect_budgets")
            let isEnvelope: Bool
            let budgetsTable: String?
            if hasZeroBudgets {
                isEnvelope = true
                budgetsTable = "zero_budgets"
            } else if hasReflectBudgets {
                isEnvelope = false
                budgetsTable = "reflect_budgets"
            } else {
                isEnvelope = true
                budgetsTable = nil
            }

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
                  AND (t.parent_id IS NULL OR p.tombstone = 0 OR p.tombstone IS NULL)
                  AND (t.isParent = 0 OR t.isParent IS NULL)
                  AND t.category IS NOT NULL
                  AND a.offbudget = 0
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

            // Determine the earliest month we need to walk from. min over any
            // budget row or any spent row. If neither, just use the target.
            let earliestMonth: Int = {
                let candidates = budgetByMonthCat.keys.map { $0 } + spentByMonthCat.keys.map { $0 }
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

            var m = earliestMonth
            while m <= targetMonthInt {
                let budgetsForMonth = budgetByMonthCat[m] ?? [:]
                let spentForMonth = spentByMonthCat[m] ?? [:]
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

            let categories = try CategoryRecord
                .filter(Column("tombstone") == 0 || Column("tombstone") == nil)
                .fetchAll(db)
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

            return BudgetMonth(month: month, categoryBudgets: categoryBudgets)
        }
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
                  AND (t.parent_id IS NULL OR par.tombstone = 0 OR par.tombstone IS NULL)
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

    func fetchWidgets() async throws -> [DashboardWidget] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, type, meta
                FROM dashboard
                WHERE (tombstone = 0 OR tombstone IS NULL)
                ORDER BY y ASC, x ASC
                """)

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

    private static func insertTransactionRow(_ db: Database, _ transaction: Transaction) throws {
        // sort_order uses current timestamp (ms) so new transactions appear at the top
        let sortOrder = Date().timeIntervalSince1970 * 1000
        try db.execute(sql: """
            INSERT INTO transactions (id, acct, date, description, category, amount, notes, cleared, reconciled, transferred_id, isParent, parent_id, tombstone, sort_order, imported_description)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                transaction.parentId,
                transaction.tombstone ? 1 : 0,
                sortOrder,
                transaction.importedPayee
            ])
    }

    // MARK: - Transaction Update

    /// Update an existing transaction's columns in place.
    /// Caller is responsible for emitting CRDT messages for the same fields.
    func updateTransaction(_ transaction: Transaction) throws {
        try dbQueue.write { db in
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
    }

    // MARK: - Rules

    /// Fetch all non-tombstoned rules from the rules table.
    /// Returns an empty array if the rules table doesn't exist.
    func fetchRules() throws -> [Rule] {
        try dbQueue.read { db in
            guard try db.tableExists("rules") else { return [] }

            let rows = try Row.fetchAll(db, sql: """
                SELECT id, stage, conditions_op, conditions, actions
                FROM rules
                WHERE tombstone = 0 OR tombstone IS NULL
                """)

            return rows.compactMap { row in
                let id: String? = row["id"]
                guard let id else { return nil }
                do {
                    return try Rule.parse(
                        id: id,
                        stage: row["stage"],
                        conditionsOp: row["conditions_op"],
                        conditionsJSON: row["conditions"],
                        actionsJSON: row["actions"]
                    )
                } catch {
                    return nil
                }
            }
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
}
