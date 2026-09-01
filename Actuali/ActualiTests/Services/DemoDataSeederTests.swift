import Foundation
import Testing
@testable import Actuali

/// Verifies the demo budget ships a valid, renderable Reports dashboard — the
/// seeded widget meta must parse to real widget types (never `.unsupported`)
/// and the engines must produce data from the seeded transactions.
// Serialized: every test seeds the same fixed "demo" budget directory, so they
// must not run in parallel against shared on-disk state.
@Suite(.serialized)
@MainActor
struct DemoDataSeederTests {

    private func seedAndOpen(tracking: Bool = false, now: Date = Date()) throws -> BudgetDatabase {
        try DemoDataSeeder.seed(tracking: tracking, now: now)
        let dbPath = BudgetFileManager.shared.databasePath(for: DemoDataSeeder.budgetId)
        return try BudgetDatabase(path: dbPath)
    }

    /// The current month as "YYYY-MM", matching the demo seeder's budget month.
    private var currentMonth: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date())
    }

    /// The tracking demo seeds `reflect_budgets` and budgets income, so the
    /// budget reads as tracking (no envelope "To Budget") and the new
    /// Saved / Projected savings summary has real figures to show.
    @Test func trackingSeedProducesATrackingBudget() async throws {
        let database = try seedAndOpen(tracking: true)
        let month = try await database.fetchBudgetMonth(month: currentMonth)

        #expect(month.toBudget == nil)
        // Tracking budgets can budget income; the seeder does, so the summary
        // has a budgeted-income figure to work with.
        #expect(month.incomeCategories.contains { $0.budgeted > 0 })
    }

    /// The default (envelope) demo keeps its "To Budget" unallocated-funds
    /// figure — the tracking flag must not leak into the normal path.
    @Test func envelopeSeedKeepsToBudget() async throws {
        let database = try seedAndOpen()
        let month = try await database.fetchBudgetMonth(month: currentMonth)

        #expect(month.toBudget != nil)
    }

    @Test func newestCheckingTransactionsStayUnclearedAtMonthEnd() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let august31 = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 12)))
        let database = try seedAndOpen(now: august31)
        let checking = try #require(try await database.fetchAccounts().first { $0.name == "Chase Checking" })
        let newest = try #require(try await database.fetchTransactions()
            .filter { $0.accountId == checking.id }
            .max { $0.date < $1.date })

        #expect(!newest.cleared)
    }

    // Two pages so the demo exercises the dashboard switcher (GH #120);
    // "Main" is first so it's the default dashboard on open.
    @Test func seedsTwoDashboardPages() async throws {
        let database = try seedAndOpen()
        let pages = try await database.fetchDashboardPages()
        #expect(pages.map(\.name) == ["Main", "Trends"])
    }

    @Test func seededDashboardWidgetsAllParseToSupportedTypes() async throws {
        let database = try seedAndOpen()
        let pages = try await database.fetchDashboardPages()
        let mainPage = try #require(pages.first { $0.name == "Main" })
        let trendsPage = try #require(pages.first { $0.name == "Trends" })

        let mainWidgets = try await database.fetchWidgets(pageId: mainPage.id)
        let trendsWidgets = try await database.fetchWidgets(pageId: trendsPage.id)

        for widget in mainWidgets + trendsWidgets {
            if case .unsupported(_, let type) = widget {
                Issue.record("Seeded widget did not parse to a supported type: \(type)")
            }
        }

        // The exact curated sets, in dashboard order (y ASC).
        #expect(mainWidgets.map(\.typeLabel) == ["Notes", "Net Worth", "Cash Flow", "Summary", "Spending", "Spending", "Spending"])
        #expect(trendsWidgets.map(\.typeLabel) == ["Notes", "Age of Money", "Summary"])
    }

    @Test func seededWidgetsProduceDataFromDemoTransactions() async throws {
        let database = try seedAndOpen()
        let pages = try await database.fetchDashboardPages()
        let mainPage = try #require(pages.first { $0.name == "Main" })
        let widgets = try await database.fetchWidgets(pageId: mainPage.id)
        let transactions = try await database.fetchTransactionsForReports()
        let today = Date()

        var netWorthMeta: NetWorthMeta?
        var summaryMeta: SummaryMeta?
        for widget in widgets {
            if case .netWorth(_, let meta) = widget { netWorthMeta = meta }
            if case .summary(_, let meta) = widget { summaryMeta = meta }
        }

        // Net worth: the seeded starting balance + activity must yield a chartable
        // series (the NetWorthWidgetView requires >= 2 points to draw).
        let netWorth = try #require(netWorthMeta)
        #expect(NetWorthEngine.compute(meta: netWorth, transactions: transactions, today: today).points.count >= 2)

        // "Spent This Month" summary must sum to a non-zero (negative) amount.
        let summary = try #require(summaryMeta)
        #expect(SummaryEngine.compute(meta: summary, transactions: transactions, today: today).totalCents < 0)
    }

    /// Every account needs a transfer payee (Actual creates one per account)
    /// or the add/edit transfer flows fail with "Transfer payee not found".
    @Test func everyAccountHasATransferPayee() async throws {
        let database = try seedAndOpen()
        let accounts = try await database.fetchAccounts()
        let payees = try await database.fetchPayees()

        #expect(!accounts.isEmpty)
        for account in accounts {
            #expect(payees.contains { $0.transferAccountId == account.id },
                    "No transfer payee for \(account.name)")
        }
    }

    /// On-budget starting balances carry the Starting Balances income category
    /// (Actual's account-creation behavior), so the demo opens with a clean
    /// uncategorized list; the off-budget brokerage's takes none and renders
    /// as "Off budget" (GH #123).
    @Test func startingBalancesAreCategorizedOnlyOnBudget() async throws {
        let database = try seedAndOpen()
        let accounts = try await database.fetchAccounts()
        let transactions = try await database.fetchTransactions()

        let startingBalances = transactions.filter { $0.payeeName == "Starting Balance" }
        #expect(startingBalances.count == 3)
        for transaction in startingBalances {
            let account = try #require(accounts.first { $0.id == transaction.accountId })
            #expect((transaction.categoryId == nil) == account.offBudget,
                    "\(account.name) starting balance miscategorized")
        }
        #expect(try await database.fetchUncategorizedCount() == 0)
    }

    /// The demo budget must support notes and ship one, or the category note
    /// section (GH #131) hides itself as unsupported and the feature is
    /// invisible in demo mode — including in App Store screenshots.
    @Test func seededBudgetShipsAnAnnotatedCategory() async throws {
        let database = try seedAndOpen()
        let groups = try await database.fetchCategoryGroups()

        let groceries = try #require(
            groups.flatMap(\.categories).first { $0.name == "Groceries" })
        let note = try await database.fetchNote(id: groceries.id)

        #expect(note.supported)
        #expect(note.text.contains("Target $650/mo"))
    }

    /// Every other category opens with an empty — not unsupported — note, so
    /// the "Add Note" row is offered rather than hidden.
    @Test func unannotatedCategoriesSupportNotes() async throws {
        let database = try seedAndOpen()
        let groups = try await database.fetchCategoryGroups()

        let rent = try #require(groups.flatMap(\.categories).first { $0.name == "Rent" })
        let note = try await database.fetchNote(id: rent.id)

        #expect(note.supported)
        #expect(note.isEmpty)
    }

    /// One demo account ships annotated too (GH #198), so the account note
    /// menu item opens onto something in demo mode rather than an empty sheet.
    @Test func seededBudgetShipsAnAnnotatedAccount() async throws {
        let database = try seedAndOpen()
        let accounts = try await database.fetchAccounts()

        let checking = try #require(accounts.first { $0.name == "Chase Checking" })
        let note = try await database.fetchNote(id: EntityNote.accountNoteId(checking.id))

        #expect(note.supported)
        #expect(note.text.contains("Direct deposit"))
        // Seeded at Actual's key, so the bare id holds nothing — the demo
        // budget mirrors a real file rather than papering over the prefix.
        #expect(try await database.fetchNote(id: checking.id).isEmpty)
    }

    /// Accounts nobody has annotated read as empty-but-supported, so the menu
    /// offers "Add Note" instead of hiding.
    @Test func unannotatedAccountsSupportNotes() async throws {
        let database = try seedAndOpen()
        let accounts = try await database.fetchAccounts()

        let savings = try #require(accounts.first { $0.name == "Ally Savings" })
        let note = try await database.fetchNote(id: EntityNote.accountNoteId(savings.id))

        #expect(note.supported)
        #expect(note.isEmpty)
    }
}
