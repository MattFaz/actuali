import Foundation
import GRDB
import os

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "DemoData")

/// Populates a local "demo" budget with curated data suitable for App Store screenshots
/// and for letting users (and App Review) explore the app without a server.
/// Overwrites any existing demo budget, and does NOT touch the server or sync.
enum DemoDataSeeder {
    static let budgetId = "demo"

    /// Creates a local "demo" budget directory with a populated SQLite DB.
    /// Overwrites any existing demo budget. Does NOT connect to a server or
    /// start sync.
    static func seed() throws {
        let fileManager = BudgetFileManager.shared
        let budgetDir = fileManager.budgetDirectory(for: budgetId)

        // Remove any existing demo budget directory and recreate fresh
        if FileManager.default.fileExists(atPath: budgetDir.path) {
            try FileManager.default.removeItem(at: budgetDir)
        }
        try FileManager.default.createDirectory(at: budgetDir, withIntermediateDirectories: true)

        // Write metadata.json
        let metadata = BudgetMetadata(
            id: budgetId,
            budgetName: "Demo Budget",
            cloudFileId: nil,
            groupId: nil,
            resetClock: nil,
            lastUploaded: nil,
            encryptKeyId: nil
        )
        let metadataData = try JSONEncoder().encode(metadata)
        try metadataData.write(to: fileManager.metadataPath(for: budgetId))

        // Open fresh SQLite DB
        let dbPath = fileManager.databasePath(for: budgetId)
        let dbQueue = try DatabaseQueue(path: dbPath.path)

        try dbQueue.write { db in
            try createSchema(db)
            try insertSeedData(db)
        }

        logger.info("Demo data seeded successfully at \(dbPath.path, privacy: .public)")
    }

    // MARK: - Schema

    private static func createSchema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE accounts (
                id TEXT PRIMARY KEY,
                name TEXT,
                type TEXT,
                offbudget INTEGER DEFAULT 0,
                closed INTEGER DEFAULT 0,
                tombstone INTEGER DEFAULT 0,
                sort_order REAL,
                account_id TEXT,
                balance_current INTEGER,
                balance_available INTEGER,
                balance_limit INTEGER,
                mask TEXT,
                official_name TEXT,
                subtype TEXT,
                bank TEXT
            )
            """)

        try db.execute(sql: """
            CREATE TABLE transactions (
                id TEXT PRIMARY KEY,
                isParent INTEGER DEFAULT 0,
                isChild INTEGER DEFAULT 0,
                acct TEXT,
                category TEXT,
                amount INTEGER,
                description TEXT,
                notes TEXT,
                date INTEGER,
                financial_id TEXT,
                type TEXT,
                location TEXT,
                error TEXT,
                imported_description TEXT,
                starting_balance_flag INTEGER DEFAULT 0,
                transferred_id TEXT,
                sort_order REAL,
                tombstone INTEGER DEFAULT 0,
                cleared INTEGER DEFAULT 0,
                reconciled INTEGER DEFAULT 0,
                parent_id TEXT,
                schedule TEXT
            )
            """)

        try db.execute(sql: """
            CREATE TABLE categories (
                id TEXT PRIMARY KEY,
                name TEXT,
                is_income INTEGER DEFAULT 0,
                cat_group TEXT,
                sort_order REAL,
                tombstone INTEGER DEFAULT 0,
                hidden BOOLEAN NOT NULL DEFAULT 0
            )
            """)

        try db.execute(sql: """
            CREATE TABLE category_groups (
                id TEXT PRIMARY KEY,
                name TEXT UNIQUE,
                is_income INTEGER DEFAULT 0,
                sort_order REAL,
                tombstone INTEGER DEFAULT 0,
                hidden BOOLEAN NOT NULL DEFAULT 0
            )
            """)

        try db.execute(sql: """
            CREATE TABLE payees (
                id TEXT PRIMARY KEY,
                name TEXT,
                category TEXT,
                tombstone INTEGER DEFAULT 0,
                transfer_acct TEXT
            )
            """)

        try db.execute(sql: """
            CREATE TABLE payee_mapping (
                id TEXT PRIMARY KEY,
                targetId TEXT
            )
            """)

        try db.execute(sql: """
            CREATE TABLE category_mapping (
                id TEXT PRIMARY KEY,
                transferId TEXT
            )
            """)

        try db.execute(sql: """
            CREATE TABLE zero_budgets (
                id TEXT PRIMARY KEY,
                month INTEGER,
                category TEXT,
                amount INTEGER DEFAULT 0,
                carryover INTEGER DEFAULT 0
            )
            """)

        try db.execute(sql: """
            CREATE TABLE preferences (
                id TEXT PRIMARY KEY,
                value TEXT
            )
            """)

        // Real Actual files key notes by the annotated row's own id (GH #131).
        // The demo budget needs the table for the category note UI to appear at
        // all — without it the section hides itself as unsupported.
        try db.execute(sql: """
            CREATE TABLE notes (
                id TEXT PRIMARY KEY,
                note TEXT
            )
            """)

        // Mirrors the dashboard tables created by BudgetDatabase's migrations, so
        // the demo budget can ship pre-built Reports dashboards.
        try db.execute(sql: """
            CREATE TABLE dashboard (
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
            """)

        try db.execute(sql: """
            CREATE TABLE dashboard_pages (
                id TEXT PRIMARY KEY,
                name TEXT,
                tombstone INTEGER DEFAULT 0
            )
            """)

        try db.execute(sql: """
            CREATE TABLE messages_crdt (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT NOT NULL UNIQUE,
                dataset TEXT NOT NULL,
                row TEXT NOT NULL,
                column TEXT NOT NULL,
                value BLOB NOT NULL
            )
            """)

        try db.execute(sql: """
            CREATE TABLE messages_clock (
                id INTEGER PRIMARY KEY,
                clock TEXT
            )
            """)

        try db.execute(sql: """
            CREATE TABLE db_version (
                version TEXT PRIMARY KEY
            )
            """)

        try db.execute(sql: """
            CREATE TABLE __migrations__ (
                id INT PRIMARY KEY NOT NULL
            )
            """)
    }

    // MARK: - Seed Data

    private static func insertSeedData(_ db: Database) throws {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let comps = cal.dateComponents([.year, .month, .day], from: now)
        let year = comps.year ?? 2026
        let month = comps.month ?? 1
        let today = comps.day ?? 15
        let yyyymm = year * 100 + month

        // --- Accounts ---
        let chaseId = UUID().uuidString
        let allyId = UUID().uuidString
        let appleCardId = UUID().uuidString
        let vanguardId = UUID().uuidString

        try insertAccount(db, id: chaseId, name: "Chase Checking", type: "checking", sortOrder: 0)
        try insertAccount(db, id: allyId, name: "Ally Savings", type: "savings", sortOrder: 1)
        try insertAccount(db, id: appleCardId, name: "Apple Card", type: "credit", sortOrder: 2)
        // Off-budget so it lifts net worth without distorting budget/spending reports.
        try insertAccount(db, id: vanguardId, name: "Vanguard Brokerage", type: "investment", sortOrder: 3, offBudget: true)

        // --- Category groups + categories ---
        // Income group
        let incomeGroupId = UUID().uuidString
        try insertCategoryGroup(db, id: incomeGroupId, name: "Income", isIncome: true, sortOrder: 0)
        let salaryId = UUID().uuidString
        try insertCategory(db, id: salaryId, name: "Salary", groupId: incomeGroupId, isIncome: true, sortOrder: 0)
        // Actual books an on-budget account's opening balance to this income
        // category at account creation; mirror that so the demo's starting
        // balances don't sit in the uncategorized list.
        let startingBalancesCategoryId = UUID().uuidString
        try insertCategory(db, id: startingBalancesCategoryId, name: "Starting Balances", groupId: incomeGroupId, isIncome: true, sortOrder: 1)

        // Essentials
        let essentialsId = UUID().uuidString
        try insertCategoryGroup(db, id: essentialsId, name: "Essentials", isIncome: false, sortOrder: 1)
        let groceriesId = UUID().uuidString
        let rentId = UUID().uuidString
        let utilitiesId = UUID().uuidString
        let internetId = UUID().uuidString
        try insertCategory(db, id: groceriesId, name: "Groceries", groupId: essentialsId, isIncome: false, sortOrder: 0)
        try insertCategory(db, id: rentId, name: "Rent", groupId: essentialsId, isIncome: false, sortOrder: 1)
        try insertCategory(db, id: utilitiesId, name: "Utilities", groupId: essentialsId, isIncome: false, sortOrder: 2)
        try insertCategory(db, id: internetId, name: "Internet", groupId: essentialsId, isIncome: false, sortOrder: 3)

        // Transport
        let transportId = UUID().uuidString
        try insertCategoryGroup(db, id: transportId, name: "Transport", isIncome: false, sortOrder: 2)
        let fuelId = UUID().uuidString
        let transitId = UUID().uuidString
        let parkingId = UUID().uuidString
        try insertCategory(db, id: fuelId, name: "Fuel", groupId: transportId, isIncome: false, sortOrder: 0)
        try insertCategory(db, id: transitId, name: "Transit", groupId: transportId, isIncome: false, sortOrder: 1)
        try insertCategory(db, id: parkingId, name: "Parking", groupId: transportId, isIncome: false, sortOrder: 2)

        // Lifestyle
        let lifestyleId = UUID().uuidString
        try insertCategoryGroup(db, id: lifestyleId, name: "Lifestyle", isIncome: false, sortOrder: 3)
        let diningId = UUID().uuidString
        let coffeeId = UUID().uuidString
        let entertainmentId = UUID().uuidString
        let shoppingId = UUID().uuidString
        try insertCategory(db, id: diningId, name: "Dining Out", groupId: lifestyleId, isIncome: false, sortOrder: 0)
        try insertCategory(db, id: coffeeId, name: "Coffee", groupId: lifestyleId, isIncome: false, sortOrder: 1)
        try insertCategory(db, id: entertainmentId, name: "Entertainment", groupId: lifestyleId, isIncome: false, sortOrder: 2)
        try insertCategory(db, id: shoppingId, name: "Shopping", groupId: lifestyleId, isIncome: false, sortOrder: 3)

        // Health & Wellness
        let healthId = UUID().uuidString
        try insertCategoryGroup(db, id: healthId, name: "Health & Wellness", isIncome: false, sortOrder: 4)
        let gymId = UUID().uuidString
        let pharmacyId = UUID().uuidString
        try insertCategory(db, id: gymId, name: "Gym", groupId: healthId, isIncome: false, sortOrder: 0)
        try insertCategory(db, id: pharmacyId, name: "Pharmacy", groupId: healthId, isIncome: false, sortOrder: 1)

        // --- Notes ---
        // One category arrives annotated so the note on the category detail
        // view (GH #131) is visible in the demo budget rather than only after
        // the user writes one.
        try insertNote(db, id: groceriesId, note: """
            Target $650/mo. Household supplies count here; \
            takeaway goes to Dining Out.
            """)
        // A second note carries a markdown link so tappable note links
        // (GH #190) are demonstrable — and UI-testable — in the demo budget.
        try insertNote(db, id: diningId, note: """
            Cap $250/mo.
            [Rewards portal](https://example.com/rewards)
            """)

        // --- Payees ---
        let wholeFoodsId = UUID().uuidString
        let traderJoesId = UUID().uuidString
        let landlordId = UUID().uuidString
        let pgeId = UUID().uuidString
        let comcastId = UUID().uuidString
        let shellId = UUID().uuidString
        let bartId = UUID().uuidString
        let chipotleId = UUID().uuidString
        let blueBottleId = UUID().uuidString
        let netflixId = UUID().uuidString
        let amazonId = UUID().uuidString
        let fitnessId = UUID().uuidString
        let cvsId = UUID().uuidString
        let paycheckId = UUID().uuidString
        let startingBalanceId = UUID().uuidString
        let vanguardPayeeId = UUID().uuidString
        let marketId = UUID().uuidString

        try insertPayee(db, id: wholeFoodsId, name: "Whole Foods")
        try insertPayee(db, id: traderJoesId, name: "Trader Joe's")
        try insertPayee(db, id: landlordId, name: "Landlord Properties LLC")
        try insertPayee(db, id: pgeId, name: "PG&E")
        try insertPayee(db, id: comcastId, name: "Comcast")
        try insertPayee(db, id: shellId, name: "Shell")
        try insertPayee(db, id: bartId, name: "BART")
        try insertPayee(db, id: chipotleId, name: "Chipotle")
        try insertPayee(db, id: blueBottleId, name: "Blue Bottle Coffee")
        try insertPayee(db, id: netflixId, name: "Netflix")
        try insertPayee(db, id: amazonId, name: "Amazon")
        try insertPayee(db, id: fitnessId, name: "24 Hour Fitness")
        try insertPayee(db, id: cvsId, name: "CVS Pharmacy")
        try insertPayee(db, id: paycheckId, name: "Paycheck")
        try insertPayee(db, id: startingBalanceId, name: "Starting Balance")
        try insertPayee(db, id: vanguardPayeeId, name: "Vanguard")
        try insertPayee(db, id: marketId, name: "Market Gain")

        // Transfer payees — one per account, name-less with transfer_acct set,
        // exactly as Actual creates them alongside each account. The add/edit
        // transfer flows resolve each leg's payee through these; without them
        // transfers can't be created in the demo.
        for accountId in [chaseId, allyId, appleCardId, vanguardId] {
            try insertPayee(db, id: UUID().uuidString, name: nil, transferAccountId: accountId)
        }

        // --- Transactions ---
        // We generate ~6 full months of history plus the current month-to-date so
        // the Reports (net worth, cash flow, spending vs. average) have real trends.
        let historyMonths = 6

        // YYYYMMDD for `day` of the month `monthsAgo` before the current month.
        // `day` is clamped to a safe 1...28 so it never rolls into the next month.
        func ymd(monthsAgo: Int, day: Int) -> Int {
            let safeDay = min(max(day, 1), 28)
            let base = cal.date(byAdding: .month, value: -monthsAgo, to: now) ?? now
            var c = cal.dateComponents([.year, .month], from: base)
            c.day = safeDay
            let d = cal.date(from: c) ?? base
            let cc = cal.dateComponents([.year, .month, .day], from: d)
            return (cc.year ?? year) * 10000 + (cc.month ?? month) * 100 + (cc.day ?? safeDay)
        }

        var transactions: [(payee: String, category: String?, amount: Int, date: Int, account: String, cleared: Bool, startingBalance: Bool)] = []

        // Starting balances ~`historyMonths` months ago, before the recurring
        // flow. On-budget ones carry the Starting Balances income category
        // (Actual's behavior); the off-budget brokerage takes none.
        let openDate = ymd(monthsAgo: historyMonths, day: 1)
        transactions.append((startingBalanceId, startingBalancesCategoryId, 1_050_000, openDate, allyId, true, true))
        transactions.append((startingBalanceId, startingBalancesCategoryId, 280_000, openDate, chaseId, true, true))
        transactions.append((startingBalanceId, nil, 4_200_000, openDate, vanguardId, true, true))

        // Per-month spending template: (payee, category, account, day, base amount in cents).
        // Slight per-month variation is applied deterministically below.
        let monthly: [(payee: String, category: String?, account: String, day: Int, amount: Int)] = [
            // Income (positive)
            (paycheckId, salaryId, chaseId, 1, 320_000),
            (paycheckId, salaryId, chaseId, 15, 320_000),
            // Essentials
            (landlordId, rentId, chaseId, 1, -185_000),
            (pgeId, utilitiesId, chaseId, 7, -8_500),
            (comcastId, internetId, chaseId, 6, -7_000),
            (wholeFoodsId, groceriesId, chaseId, 3, -8_750),
            (traderJoesId, groceriesId, chaseId, 11, -5_200),
            (wholeFoodsId, groceriesId, chaseId, 19, -9_600),
            (traderJoesId, groceriesId, chaseId, 26, -6_300),
            // Transport
            (shellId, fuelId, chaseId, 9, -5_500),
            (shellId, fuelId, chaseId, 23, -6_000),
            (bartId, transitId, chaseId, 4, -2_500),
            (bartId, transitId, chaseId, 18, -2_500),
            // Lifestyle (mostly Apple Card)
            (chipotleId, diningId, appleCardId, 5, -1_450),
            (chipotleId, diningId, appleCardId, 16, -2_500),
            (chipotleId, diningId, appleCardId, 24, -1_725),
            (blueBottleId, coffeeId, appleCardId, 2, -575),
            (blueBottleId, coffeeId, appleCardId, 8, -650),
            (blueBottleId, coffeeId, appleCardId, 14, -700),
            (blueBottleId, coffeeId, appleCardId, 21, -550),
            (netflixId, entertainmentId, appleCardId, 11, -2_299),
            (amazonId, shoppingId, appleCardId, 6, -4_599),
            (amazonId, shoppingId, appleCardId, 20, -3_199),
            // Health & wellness
            (fitnessId, gymId, chaseId, 10, -3_500),
            (cvsId, pharmacyId, chaseId, 13, -1_850),
            // Off-budget: monthly brokerage contribution
            (vanguardPayeeId, nil, vanguardId, 2, 50_000),
        ]

        for monthsAgo in stride(from: historyMonths, through: 0, by: -1) {
            // Deterministic per-month wiggle so months aren't identical.
            let wiggle = [0, 7, -4, 11, -8, 5, 3][min(monthsAgo, 6)]
            for item in monthly {
                // Current month: only include entries up to today (month-to-date).
                if monthsAgo == 0 && item.day > today { continue }
                let varied: Int
                if item.amount < 0 {
                    // Vary discretionary spend by a few percent; keep fixed bills exact.
                    let isFixed = item.category == rentId || item.category == internetId
                        || item.category == gymId || item.category == entertainmentId
                    varied = isFixed ? item.amount : item.amount + (item.amount / 100) * wiggle
                } else {
                    varied = item.amount
                }
                // Older transactions are reconciled/cleared; the newest are still pending.
                let cleared = !(monthsAgo == 0 && item.day > max(today - 3, 0))
                transactions.append((item.payee, item.category, varied,
                                     ymd(monthsAgo: monthsAgo, day: item.day),
                                     item.account, cleared, false))
            }

            // Quarterly market gains on the brokerage account, so net worth trends up.
            if monthsAgo % 3 == 0 {
                transactions.append((marketId, nil, 95_000 + 5_000 * (historyMonths - monthsAgo),
                                     ymd(monthsAgo: monthsAgo, day: 28), vanguardId, true, false))
            }
        }

        // Newest first, so sort_order (descending) matches date order.
        transactions.sort { $0.date > $1.date }
        var sortOrder = Date().timeIntervalSince1970 * 1000
        for t in transactions {
            try insertTransaction(
                db,
                id: UUID().uuidString,
                accountId: t.account,
                date: t.date,
                amount: t.amount,
                payeeId: t.payee,
                categoryId: t.category,
                cleared: t.cleared,
                startingBalance: t.startingBalance,
                sortOrder: sortOrder
            )
            sortOrder -= 1
        }

        // --- Zero budgets (current month) ---
        let budgets: [(String, Int)] = [
            (groceriesId, 60_000),
            (rentId, 185_000),
            (utilitiesId, 10_000),
            (internetId, 7_000),
            (fuelId, 15_000),
            (transitId, 8_000),
            (parkingId, 2_000),
            (diningId, 20_000),
            (coffeeId, 4_000),
            (entertainmentId, 5_000),
            (shoppingId, 15_000),
            (gymId, 3_500),
            (pharmacyId, 3_000)
        ]
        for (catId, amount) in budgets {
            try db.execute(sql: """
                INSERT INTO zero_budgets (id, month, category, amount, carryover)
                VALUES (?, ?, ?, ?, 0)
                """, arguments: [UUID().uuidString, yyyymm, catId, amount])
        }

        // --- Preferences ---
        try db.execute(sql: """
            INSERT INTO preferences (id, value) VALUES ('defaultCurrencyCode', 'USD')
            """)

        // --- Reports dashboards ---
        // Two pages so the demo exercises the dashboard switcher (GH #120);
        // "Main" is inserted first so it's the default dashboard on open.
        let mainPageId = UUID().uuidString
        let trendsPageId = UUID().uuidString
        try db.execute(sql: """
            INSERT INTO dashboard_pages (id, name, tombstone)
            VALUES (?, 'Main', 0), (?, 'Trends', 0)
            """, arguments: [mainPageId, trendsPageId])

        // A curated set of widgets so the Reports tab is populated in the demo.
        // Sliding-window time frames slide their stored range forward to end at
        // the current month, so the net-worth/cash-flow trends always cover the
        // seeded data regardless of when the demo is loaded. Ordered by `y`.
        try insertWidget(db, pageId: mainPageId, type: "markdown-card", y: 0, width: 12, height: 2, meta: """
            {"content":"**Welcome to the demo** 👋\\n\\nThis is sample data stored only on this device \u{2014} nothing you do here can touch a server or a real budget. When you\u{2019}re ready, connect your own Actual Budget server in **Settings**."}
            """)
        try insertWidget(db, pageId: mainPageId, type: "net-worth-card", y: 1, width: 12, height: 2, meta: """
            {"name":"Net Worth","timeFrame":{"start":"2024-01","end":"2024-06","mode":"sliding-window"},"interval":"Monthly"}
            """)
        try insertWidget(db, pageId: mainPageId, type: "cash-flow-card", y: 2, width: 12, height: 2, meta: """
            {"name":"Cash Flow","timeFrame":{"start":"2024-01","end":"2024-06","mode":"sliding-window"},"showBalance":false}
            """)
        try insertWidget(db, pageId: mainPageId, type: "summary-card", y: 3, width: 12, height: 2, meta: """
            {"name":"Spent This Month","content":"{\\"type\\":\\"sum\\"}","conditions":[{"field":"amount","op":"lt","value":0}],"conditionsOp":"and"}
            """)
        try insertWidget(db, pageId: mainPageId, type: "spending-card", y: 4, width: 12, height: 2, meta: """
            {"name":"This Month","mode":"single-month"}
            """)
        try insertWidget(db, pageId: mainPageId, type: "spending-card", y: 5, width: 12, height: 2, meta: """
            {"name":"Budget Overview","mode":"budget"}
            """)
        try insertWidget(db, pageId: mainPageId, type: "spending-card", y: 6, width: 12, height: 2, meta: """
            {"name":"3-Month Average","mode":"average"}
            """)

        // The second dashboard: a small page that shows off switching.
        try insertWidget(db, pageId: trendsPageId, type: "markdown-card", y: 0, width: 12, height: 2, meta: """
            {"content":"**A second dashboard** 📊\\n\\nBudgets can have several report dashboards \u{2014} switch between them with the menu in the top corner. Create and arrange dashboards in the Actual Budget webapp."}
            """)
        try insertWidget(db, pageId: trendsPageId, type: "age-of-money-card", y: 1, width: 12, height: 2, meta: """
            {"name":"Age of Money"}
            """)
        try insertWidget(db, pageId: trendsPageId, type: "summary-card", y: 2, width: 12, height: 2, meta: """
            {"name":"Income This Month","content":"{\\"type\\":\\"sum\\"}","conditions":[{"field":"amount","op":"gt","value":0}],"conditionsOp":"and"}
            """)

        logger.info("Inserted \(transactions.count) demo transactions for month \(yyyymm)")
    }

    private static func insertWidget(
        _ db: Database,
        pageId: String,
        type: String,
        y: Int,
        width: Int,
        height: Int,
        meta: String
    ) throws {
        try db.execute(sql: """
            INSERT INTO dashboard (id, type, dashboard_page_id, x, y, width, height, meta, tombstone)
            VALUES (?, ?, ?, 0, ?, ?, ?, ?, 0)
            """, arguments: [UUID().uuidString, type, pageId, y, width, height, meta])
    }

    // MARK: - Insert helpers

    private static func insertAccount(
        _ db: Database,
        id: String,
        name: String,
        type: String,
        sortOrder: Double,
        offBudget: Bool = false
    ) throws {
        try db.execute(sql: """
            INSERT INTO accounts (id, name, type, offbudget, closed, tombstone, sort_order)
            VALUES (?, ?, ?, ?, 0, 0, ?)
            """, arguments: [id, name, type, offBudget ? 1 : 0, sortOrder])
    }

    private static func insertCategoryGroup(
        _ db: Database,
        id: String,
        name: String,
        isIncome: Bool,
        sortOrder: Double
    ) throws {
        try db.execute(sql: """
            INSERT INTO category_groups (id, name, is_income, sort_order, tombstone, hidden)
            VALUES (?, ?, ?, ?, 0, 0)
            """, arguments: [id, name, isIncome ? 1 : 0, sortOrder])
    }

    private static func insertCategory(
        _ db: Database,
        id: String,
        name: String,
        groupId: String,
        isIncome: Bool,
        sortOrder: Double
    ) throws {
        try db.execute(sql: """
            INSERT INTO categories (id, name, is_income, cat_group, sort_order, tombstone, hidden)
            VALUES (?, ?, ?, ?, ?, 0, 0)
            """, arguments: [id, name, isIncome ? 1 : 0, groupId, sortOrder])
    }

    private static func insertNote(
        _ db: Database,
        id: String,
        note: String
    ) throws {
        try db.execute(sql: """
            INSERT INTO notes (id, note) VALUES (?, ?)
            """, arguments: [id, note])
    }

    private static func insertPayee(
        _ db: Database,
        id: String,
        name: String?,
        transferAccountId: String? = nil
    ) throws {
        try db.execute(sql: """
            INSERT INTO payees (id, name, transfer_acct, tombstone) VALUES (?, ?, ?, 0)
            """, arguments: [id, name, transferAccountId])
        // Required for the transactions JOIN to resolve payee name
        try db.execute(sql: """
            INSERT INTO payee_mapping (id, targetId) VALUES (?, ?)
            """, arguments: [id, id])
    }

    private static func insertTransaction(
        _ db: Database,
        id: String,
        accountId: String,
        date: Int,
        amount: Int,
        payeeId: String,
        categoryId: String?,
        cleared: Bool,
        startingBalance: Bool,
        sortOrder: Double
    ) throws {
        try db.execute(sql: """
            INSERT INTO transactions (
                id, isParent, isChild, acct, category, amount, description, notes, date,
                starting_balance_flag, sort_order, tombstone, cleared, reconciled
            )
            VALUES (?, 0, 0, ?, ?, ?, ?, NULL, ?, ?, ?, 0, ?, 0)
            """, arguments: [
                id,
                accountId,
                categoryId,
                amount,
                payeeId,
                date,
                startingBalance ? 1 : 0,
                sortOrder,
                cleared ? 1 : 0
            ])
    }
}
