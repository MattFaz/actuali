import Foundation
import Testing
@testable import Actuali

/// Verifies the demo budget ships a valid, renderable Reports dashboard — the
/// seeded widget meta must parse to real widget types (never `.unsupported`)
/// and the engines must produce data from the seeded transactions.
// Serialized: every seed writes the same fixed "demo" budget directory, so the
// fixtures below must not build in parallel against shared on-disk state.
@Suite(.serialized)
@MainActor
struct DemoDataSeederTests {
    /// A seeded demo file, copied out of the shared demo directory (the next
    /// configuration's seed wipes it). No test writes after seeding, so each
    /// configuration seeds once and every test opens its own copy.
    private struct Seed: Sendable {
        let url: URL
        /// The instant the seeder was given, so date assertions share the
        /// seed's reference rather than a second `Date()` that could
        /// straddle local midnight.
        let now: Date
    }

    private static let defaultSeed = Result { try seed() }
    private static let trackingSeed = Result { try seed(tracking: true) }
    private static let uncategorizedSeed = Result { try seed(seedUncategorized: true) }
    private static let unsupportedBankSyncSeed = Result { try seed(seedUnsupportedBankSync: true) }
    private static let august31Seed = Result {
        try seed(now: Calendar(identifier: .gregorian)
            .date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 12))!)
    }

    private nonisolated static func seed(
        tracking: Bool = false,
        seedUncategorized: Bool = false,
        seedUnsupportedBankSync: Bool = false,
        now: Date = Date()
    ) throws -> Seed {
        try DemoDataSeeder.seed(
            tracking: tracking,
            seedUncategorized: seedUncategorized,
            seedUnsupportedBankSync: seedUnsupportedBankSync,
            now: now
        )
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("demo-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(
            at: BudgetFileManager.shared.databasePath(for: DemoDataSeeder.budgetId), to: copy
        )
        return Seed(url: copy, now: now)
    }

    private func open(_ seed: Result<Seed, any Error>) throws -> BudgetDatabase {
        try BudgetDatabase(path: seed.get().url)
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
        let database = try open(Self.trackingSeed)
        let month = try await database.fetchBudgetMonth(month: currentMonth)

        #expect(month.toBudget == nil)
        // Tracking budgets can budget income; the seeder does, so the summary
        // has a budgeted-income figure to work with.
        #expect(month.incomeCategories.contains { $0.budgeted > 0 })
    }

    /// The Budget screen's uncategorized bar renders only when an on-budget
    /// transaction lacks a category, and the default demo seed has none — the
    /// `seedUncategorized` hook exists so UI tests can render the bar.
    @Test func seedUncategorizedAddsExactlyOneUncategorizedTransaction() async throws {
        let defaultSeed = try open(Self.defaultSeed)
        #expect(try await defaultSeed.fetchUncategorizedCount() == 0)

        let seeded = try open(Self.uncategorizedSeed)
        #expect(try await seeded.fetchUncategorizedCount() == 1)
    }

    /// `seedUnsupportedBankSync` links two accounts to providers Actuali can't
    /// refresh (GH #499); the default demo stays unlinked.
    @Test func seedUnsupportedBankSyncLinksGoCardlessAndPluggy() async throws {
        #expect(try await open(Self.defaultSeed).fetchBankSyncAccounts().isEmpty)

        let linked = try await open(Self.unsupportedBankSyncSeed).fetchBankSyncAccounts()
        #expect(Dictionary(uniqueKeysWithValues: linked.map { ($0.name, $0.syncSource) }) == [
            "Chase Checking": "goCardless",
            "Ally Savings": "pluggyai",
        ])
        #expect(linked.allSatisfy { !$0.externalAccountId.isEmpty })
    }

    /// The default (envelope) demo keeps its "To Budget" unallocated-funds
    /// figure — the tracking flag must not leak into the normal path.
    @Test func envelopeSeedKeepsToBudget() async throws {
        let database = try open(Self.defaultSeed)
        let month = try await database.fetchBudgetMonth(month: currentMonth)

        #expect(month.toBudget != nil)
    }

    @Test func newestCheckingTransactionsStayUnclearedAtMonthEnd() async throws {
        let database = try open(Self.august31Seed)
        let checking = try #require(try await database.fetchAccounts().first { $0.name == "Chase Checking" })
        let newest = try #require(try await database.fetchTransactions()
            .filter { $0.accountId == checking.id }
            .max { $0.date < $1.date })

        #expect(!newest.cleared)
    }

    /// Two pages so the demo exercises the dashboard switcher (GH #120);
    /// "Main" is first so it's the default dashboard on open.
    @Test func seedsTwoDashboardPages() async throws {
        let database = try open(Self.defaultSeed)
        let pages = try await database.fetchDashboardPages()
        #expect(pages.map(\.name) == ["Main", "Trends"])
    }

    @Test func seededDashboardWidgetsAllParseToSupportedTypes() async throws {
        let database = try open(Self.defaultSeed)
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
        let database = try open(Self.defaultSeed)
        let pages = try await database.fetchDashboardPages()
        let mainPage = try #require(pages.first { $0.name == "Main" })
        let widgets = try await database.fetchWidgets(pageId: mainPage.id)
        let transactions = try await database.fetchTransactionsForReports()
        let today = Date()

        var netWorthMeta: NetWorthMeta?
        var summaryMeta: SummaryMeta?
        for widget in widgets {
            if case .netWorth(_, let meta) = widget {
                netWorthMeta = meta
            }
            if case .summary(_, let meta) = widget {
                summaryMeta = meta
            }
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
    /// The demo ships a rules table (Settings > Rules must show the list, not
    /// the "Rules Unavailable" placeholder) and two upcoming schedules backed
    /// by their own rules, per ScheduleWriteBuilder.createPlan's shape.
    @Test func seedsRulesAndSchedules() async throws {
        let database = try open(Self.defaultSeed)

        let rules = try await database.fetchRulesRanked()
        #expect(rules.count == 3)

        let schedules = try await database.fetchSchedules()
        #expect(schedules.compactMap(\.name).sorted() == ["Netflix", "Rent"])
        // Every schedule resolves its payee/account from the rule conditions,
        // and the recurrence's day pattern matches the stored next date —
        // mismatched patterns advance to the wrong day after the first post.
        for schedule in schedules {
            #expect(schedule.payeeId != nil && schedule.accountId != nil,
                    "Schedule \(schedule.name ?? "?") is missing payee/account conditions")
            guard case .recurring(let config) = try #require(schedule.dateCondition),
                  let next = schedule.nextDate else { continue }
            let patternDays = config.patterns.filter { $0.type == "day" }.map(\.value)
            #expect(patternDays.contains(next.day),
                    "\(schedule.name ?? "?") recurs on \(patternDays) but next date is \(next)")
        }
    }

    /// Seeded schedules must be strictly future-dated: the auto-poster
    /// (SchedulePoster.runIfNeeded) posts every schedule whose next date is
    /// today or past, and a fresh demo load must never mutate its own seeded
    /// data (or record history) on its own.
    @Test func seededSchedulesAreNeverDueOnLoad() async throws {
        let seed = try Self.defaultSeed.get()
        let schedules = try await BudgetDatabase(path: seed.url).fetchSchedules()
        #expect(!schedules.isEmpty)
        let today = DayDate.today(now: seed.now)
        for schedule in schedules {
            let next = try #require(schedule.nextDate)
            #expect(next > today, "\(schedule.name ?? "?") is due at load")
        }
    }

    @Test func everyAccountHasATransferPayee() async throws {
        let database = try open(Self.defaultSeed)
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
        let database = try open(Self.defaultSeed)
        let accounts = try await database.fetchAccounts()
        let transactions = try await database.fetchTransactions()

        let startingBalances = transactions.filter { $0.payeeName == "Starting Balance" }
        #expect(startingBalances.count == 5)
        for transaction in startingBalances {
            let account = try #require(accounts.first { $0.id == transaction.accountId })
            #expect((transaction.categoryId == nil) == account.offBudget,
                    "\(account.name) starting balance miscategorized")
        }
        #expect(try await database.fetchUncategorizedCount() == 0)
    }

    /// The demo tracks a loan and a deposit so both features show in demo
    /// mode. The loan must be off-budget (Record Payment refuses otherwise),
    /// paid down by paired transfers, and the CD must have earned interest.
    @Test func seedsATrackedLoanAndDeposit() async throws {
        let database = try open(Self.defaultSeed)
        let accounts = try await database.fetchAccounts()
        let transactions = try await database.fetchTransactions()

        let (loanId, loan) = try #require(try await database.fetchLoanConfigs().first)
        let loanAccount = try #require(accounts.first { $0.id == loanId })
        #expect(loanAccount.offBudget)
        #expect(loanAccount.balance > -loan.originalBalance)
        #expect(loan.categoryId != nil)

        let payments = transactions.filter { $0.accountId == loanId && $0.transferId != nil }
        #expect(!payments.isEmpty)
        for payment in payments {
            let partner = try #require(transactions.first { $0.id == payment.transferId })
            #expect(partner.transferId == payment.id)
            #expect(partner.categoryId == loan.categoryId)
        }

        let (depositId, deposit) = try #require(try await database.fetchDepositConfigs().first)
        let depositAccount = try #require(accounts.first { $0.id == depositId })
        #expect(depositAccount.balance > deposit.amount)
    }

    @Test func seedsCardMappingsToOpenAccounts() async throws {
        let database = try open(Self.defaultSeed)
        let accountsByName = try await Dictionary(uniqueKeysWithValues: database.fetchAccounts().map { ($0.name, $0.id) })
        let mappings = try await database.fetchCardAccountMappings()

        #expect(mappings == [
            "4417": accountsByName["Apple Card"],
            "Goldman Sachs": accountsByName["Apple Card"],
            "8830": accountsByName["Chase Checking"],
        ])
    }

    /// The demo budget must support notes and ship one, or the category note
    /// section (GH #131) hides itself as unsupported and the feature is
    /// invisible in demo mode — including in App Store screenshots.
    @Test func seededBudgetShipsAnAnnotatedCategory() async throws {
        let database = try open(Self.defaultSeed)
        let groups = try await database.fetchCategoryGroups()

        let groceries = try #require(
            groups.flatMap(\.categories).first { $0.name == "Groceries" }
        )
        let note = try await database.fetchNote(id: groceries.id)

        #expect(note.supported)
        #expect(note.text.contains("Target $650/mo"))
    }

    /// Every other category opens with an empty — not unsupported — note, so
    /// the "Add Note" row is offered rather than hidden.
    @Test func unannotatedCategoriesSupportNotes() async throws {
        let database = try open(Self.defaultSeed)
        let groups = try await database.fetchCategoryGroups()

        let rent = try #require(groups.flatMap(\.categories).first { $0.name == "Rent" })
        let note = try await database.fetchNote(id: rent.id)

        #expect(note.supported)
        #expect(note.isEmpty)
    }

    /// One demo account ships annotated too (GH #198), so the account note
    /// menu item opens onto something in demo mode rather than an empty sheet.
    @Test func seededBudgetShipsAnAnnotatedAccount() async throws {
        let database = try open(Self.defaultSeed)
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
        let database = try open(Self.defaultSeed)
        let accounts = try await database.fetchAccounts()

        let savings = try #require(accounts.first { $0.name == "Ally Savings" })
        let note = try await database.fetchNote(id: EntityNote.accountNoteId(savings.id))

        #expect(note.supported)
        #expect(note.isEmpty)
    }

    @Test func seededBudgetShipsTagsAndTaggedTransactions() async throws {
        let database = try open(Self.defaultSeed)
        let tags = try await database.fetchTags(includeHidden: true)

        #expect(tags.count >= 5)
        let tagNames = Set(tags.map(\.tag))
        #expect(tagNames.contains("coffee"))
        #expect(tagNames.contains("vacation"))
        #expect(tagNames.contains("reimbursable"))
        #expect(tagNames.contains("tax-deductible"))
        #expect(tagNames.contains("refund"))

        let transactions = try await database.fetchTransactions()
        let taggedTransactions = transactions.filter { $0.notes?.contains("#") == true }
        #expect(!taggedTransactions.isEmpty)

        let summaries = try await database.fetchTagSummaries()
        #expect(!summaries.isEmpty)
        let coffeeSummary = summaries.first { $0.tag.tag == "coffee" }
        #expect(coffeeSummary != nil)
        #expect((coffeeSummary?.transactionCount ?? 0) > 0)
        #expect((coffeeSummary?.totalSpent ?? 0) > 0)

        let refundSummary = summaries.first { $0.tag.tag == "refund" }
        #expect(refundSummary != nil)
        #expect((refundSummary?.transactionCount ?? 0) > 0)
        #expect(refundSummary?.totalSpent == 0)
        #expect((refundSummary?.netAmount ?? 0) > 0)
    }

    @Test func seedPendingImportsAddsSampleWithCurrencyMismatch() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = PendingImportStore(fileURL: tempDir.appendingPathComponent("pending.json"))

        try DemoDataSeeder.seedPendingImports(store: store)

        #expect(store.count == 1)
        let first = store.imports.first
        #expect(first?.sourceCurrencyCode == "INR")
        #expect(first?.amount == 156.0)
        #expect(first?.payee == "SWIGGY INST")
        #expect(first?.originBudgetId == DemoDataSeeder.budgetId)

        // Idempotency: second call does not re-add or clear
        try DemoDataSeeder.seedPendingImports(store: store)
        #expect(store.count == 1)
    }

    @Test func removeSamplePendingImportKeepsOtherDemoImports() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = PendingImportStore(fileURL: tempDir.appendingPathComponent("pending.json"))
        let queuedInDemo = PendingImport(originBudgetId: DemoDataSeeder.budgetId, amount: 12)

        try DemoDataSeeder.seedPendingImports(store: store)
        try store.add(queuedInDemo)
        try DemoDataSeeder.removeSamplePendingImport(store: store)

        #expect(store.imports.map(\.id) == [queuedInDemo.id])
    }
}
