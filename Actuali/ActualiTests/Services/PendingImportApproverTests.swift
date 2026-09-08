import Foundation
import GRDB
import Testing
@testable import Actuali

@MainActor
struct PendingImportApproverTests {

    private func makeStore() -> BudgetStore {
        let store = BudgetStore.previewInstance()
        // Unique per test: `defaultAccountId` is UserDefaults keyed by budget id,
        // and these tests run in parallel — a shared id lets one test's default
        // account bleed into another's resolution.
        store.currentBudgetId = "test-budget-\(UUID().uuidString)"
        return store
    }

    /// Non-async so GRDB's `write` resolves to its synchronous overload.
    private func makeDatabaseFile() throws -> (BudgetDatabase, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY, starting_balance_flag INTEGER DEFAULT 0,
                    isParent INTEGER DEFAULT 0, isChild INTEGER DEFAULT 0,
                    acct TEXT, category TEXT, amount INTEGER, description TEXT,
                    notes TEXT, date INTEGER, imported_description TEXT,
                    financial_id TEXT, transferred_id TEXT, sort_order REAL,
                    tombstone INTEGER DEFAULT 0, cleared INTEGER DEFAULT 0,
                    reconciled INTEGER DEFAULT 0, parent_id TEXT
                )
                """)
            try db.execute(sql: """
                CREATE TABLE payees (id TEXT PRIMARY KEY, name TEXT,
                    transfer_acct TEXT, tombstone INTEGER DEFAULT 0)
                """)
            try db.execute(sql: "CREATE TABLE payee_mapping (id TEXT PRIMARY KEY, targetId TEXT)")
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY, name TEXT, offbudget INTEGER DEFAULT 0,
                    closed INTEGER DEFAULT 0, tombstone INTEGER DEFAULT 0
                )
                """)
            try db.execute(sql: """
                CREATE TABLE category_mapping (id TEXT PRIMARY KEY, transferId TEXT)
                """)
            try db.execute(sql: """
                CREATE TABLE categories (
                    id TEXT PRIMARY KEY, name TEXT, cat_group TEXT,
                    tombstone INTEGER DEFAULT 0
                )
                """)
            try db.execute(sql: """
                CREATE TABLE messages_crdt (id INTEGER PRIMARY KEY,
                    timestamp TEXT NOT NULL UNIQUE, dataset TEXT NOT NULL,
                    row TEXT NOT NULL, column TEXT NOT NULL, value BLOB NOT NULL)
                """)
            try db.execute(sql: """
                CREATE TABLE rules (id TEXT PRIMARY KEY, stage TEXT, conditions TEXT,
                    actions TEXT, tombstone INTEGER DEFAULT 0,
                    conditions_op TEXT DEFAULT 'and')
                """)
        }
        return (try BudgetDatabase(path: url), url)
    }

    /// A store with a real (temp-file) budget database wired, so the approve
    /// success path can write and the resulting signed amount can be checked.
    private func makeWritableStore() async throws -> (BudgetStore, URL) {
        let (database, url) = try makeDatabaseFile()
        let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")

        let store = makeStore()
        store.configureForTesting(database: database, syncClient: syncClient)
        return (store, url)
    }

    private func account(_ id: String, _ name: String, closed: Bool = false) -> Account {
        Account(id: id, name: name, type: .checking, offBudget: false, closed: closed,
                sortOrder: 0, balance: 0)
    }

    @Test func refusesInvalidAmount() async {
        let store = makeStore()
        let approver = PendingImportApprover(store: store)

        let nilAmountItem = PendingImport(amount: nil, payee: "Test", rawText: "test")
        await #expect(throws: PendingImportApprover.ApproveError.invalidAmount) {
            try await approver.approve(nilAmountItem)
        }

        let zeroAmountItem = PendingImport(amount: 0, payee: "Test", rawText: "test")
        await #expect(throws: PendingImportApprover.ApproveError.invalidAmount) {
            try await approver.approve(zeroAmountItem)
        }

        let negativeAmountItem = PendingImport(amount: -15.0, payee: "Test", rawText: "test")
        await #expect(throws: PendingImportApprover.ApproveError.invalidAmount) {
            try await approver.approve(negativeAmountItem)
        }
    }

    @Test func refusesWhenNoAccountAvailable() async {
        let store = makeStore()
        store.accounts = []
        store.defaultAccountId = nil

        let approver = PendingImportApprover(store: store)
        let item = PendingImport(originBudgetId: store.currentBudgetId, amount: 25.0, sourceCurrencyCode: "USD", payee: "Coffee", cardHint: "nonexistent", rawText: "msg")

        await #expect(throws: PendingImportApprover.ApproveError.noAccountAvailable) {
            try await approver.approve(item)
        }
    }

    @Test func refusesLegacyImportWithoutAutomaticApproval() async {
        let store = makeStore()
        store.accounts = [account("acct_cash", "Cash")]

        await #expect(throws: PendingImportApprover.ApproveError.budgetIdentityRequired) {
            try await PendingImportApprover(store: store).approve(
                PendingImport(amount: 25.0, payee: "Coffee", rawText: "msg"))
        }
    }

    @Test func refusesImportFromAnotherBudget() async {
        let store = makeStore()
        store.accounts = [account("acct_cash", "Cash")]

        await #expect(throws: PendingImportApprover.ApproveError.budgetMismatch) {
            try await PendingImportApprover(store: store).approve(
                PendingImport(originBudgetId: "different-budget", amount: 25.0,
                              payee: "Coffee", rawText: "msg"))
        }
    }

    @Test func combinedDirectApprovalLeavesBothReviewRequirementsForEditor() async {
        let store = makeStore()
        store.accounts = [account("acct_cash", "Cash")]
        store.currencyCode = "USD"
        let item = PendingImport(
            originBudgetId: "different-budget", amount: 25.0,
            sourceCurrencyCode: "EUR", payee: "Coffee", rawText: "msg"
        )

        await #expect(throws: PendingImportApprover.ApproveError.budgetMismatch) {
            try await PendingImportApprover(store: store).approve(item)
        }
        #expect(item.reviewRequirements(
            activeBudgetId: store.currentBudgetId,
            budgetCurrency: store.currencyCode
        ) == [
            .adoptIntoActiveBudget,
            .confirmActiveBudgetCurrency(source: "EUR", budget: "USD")
        ])
    }

    @Test func refusesKnownCurrencyMismatch() async {
        let store = makeStore()
        store.accounts = [account("acct_cash", "Cash")]
        store.currencyCode = "USD"

        await #expect(throws: PendingImportApprover.ApproveError.sourceCurrencyMismatch(source: "EUR", budget: "USD")) {
            try await PendingImportApprover(store: store).approve(
                PendingImport(originBudgetId: store.currentBudgetId, amount: 25.0,
                              sourceCurrencyCode: "EUR", payee: "Coffee", rawText: "msg"))
        }
    }

    @Test func refusesDirectApprovalWhenNoMappingOrDefaultExists() async {
        let store = makeStore()
        store.accounts = [account("acct_closed", "Closed", closed: true), account("acct_cash", "Cash")]
        store.defaultAccountId = nil

        await #expect(throws: PendingImportApprover.ApproveError.noAccountAvailable) {
            try await PendingImportApprover(store: store).approve(
                PendingImport(originBudgetId: store.currentBudgetId, amount: 12.50,
                              sourceCurrencyCode: "USD", payee: "Coffee", cardHint: "unknown"))
        }
    }

    @Test func directApprovalUsesFirstOpenAccountOnlyWhenExplicitlyDefaulted() async throws {
        let (store, url) = try await makeWritableStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.accounts = [account("acct_closed", "Closed", closed: true), account("acct_cash", "Cash")]
        store.defaultAccountId = "acct_cash"

        let result = try await PendingImportApprover(store: store).approve(
            PendingImport(originBudgetId: store.currentBudgetId, amount: 12.50,
                          sourceCurrencyCode: "USD", payee: "Coffee", cardHint: "unknown"))

        #expect(result.transaction.accountId == "acct_cash")
    }

    @Test func refusesUnknownCurrencyForDirectApproval() async {
        let store = makeStore()
        store.accounts = [account("acct_cash", "Cash")]

        await #expect(throws: PendingImportApprover.ApproveError.sourceCurrencyRequired) {
            try await PendingImportApprover(store: store).approve(
                PendingImport(originBudgetId: store.currentBudgetId, amount: 25.0,
                              payee: "Coffee", rawText: "msg"))
        }
    }

    @Test func closedMappingWithoutDefaultRefusesDirectApproval() async {
        let store = makeStore()
        store.accounts = [account("acct_closed", "Old Card", closed: true), account("acct_cash", "Cash")]
        store.cardAccountMappings = ["1234": "acct_closed"]
        store.defaultAccountId = nil

        await #expect(throws: PendingImportApprover.ApproveError.noAccountAvailable) {
            try await PendingImportApprover(store: store).approve(
                PendingImport(originBudgetId: store.currentBudgetId, amount: 12.50,
                              sourceCurrencyCode: "USD", payee: "Coffee", cardHint: "1234"))
        }
    }

    @Test func refusesWhenTargetAccountIsClosed() async {
        let store = makeStore()
        let closedAcct = account("acct_closed", "Closed Account", closed: true)
        store.accounts = [closedAcct]
        store.defaultAccountId = closedAcct.id

        let approver = PendingImportApprover(store: store)
        let item = PendingImport(originBudgetId: store.currentBudgetId, amount: 25.0, sourceCurrencyCode: "USD", payee: "Coffee", rawText: "msg")

        await #expect(throws: PendingImportApprover.ApproveError.noAccountAvailable) {
            try await approver.approve(item)
        }
    }

    @Test func closedDefaultDoesNotQualifyForDirectApproval() {
        let accounts = [account("acct_closed", "Closed", closed: true), account("acct_open", "Open")]
        #expect(PendingImportApprover.resolveAccountId(
            cardHint: nil, accounts: accounts, cardMappings: [:], defaultAccountId: "acct_closed"
        ) == nil)
        #expect(PendingImportApprover.seedAccountId(
            cardHint: nil, accounts: accounts, cardMappings: [:], defaultAccountId: "acct_closed"
        ) == "acct_open")
    }

    @Test func logsExpenseAsNegativeAndRoutesByCardHint() async throws {
        let (store, url) = try await makeWritableStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.accounts = [account("acct_checking", "Checking")]

        let approver = PendingImportApprover(store: store)
        // cardHint matches the account name, so resolution uses the hint route,
        // not the default account.
        let item = PendingImport(originBudgetId: store.currentBudgetId, amount: 18.50, sourceCurrencyCode: "USD", payee: "Starbucks", cardHint: "Checking",
                                 isIncome: false, rawText: "msg")

        let result = try await approver.approve(item)

        #expect(result.transaction.accountId == "acct_checking")
        #expect(result.transaction.amount == -1850)
        // Parsed imports aren't bank-confirmed, so they land uncleared.
        #expect(result.transaction.cleared == false)
    }

    @Test func logsIncomeAsPositiveViaDefaultAccount() async throws {
        let (store, url) = try await makeWritableStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.accounts = [account("acct_checking", "Checking")]
        store.defaultAccountId = "acct_checking"

        let approver = PendingImportApprover(store: store)
        let item = PendingImport(originBudgetId: store.currentBudgetId, amount: 25.0, sourceCurrencyCode: "USD", payee: "Employer", isIncome: true, rawText: "msg")

        let result = try await approver.approve(item)

        #expect(result.transaction.accountId == "acct_checking")
        #expect(result.transaction.amount == 2500)
        #expect(result.transaction.cleared == false)
    }

    @Test func retryAfterSuccessfulWriteIsReportedAsAlreadyApproved() async throws {
        let (store, url) = try await makeWritableStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.accounts = [account("acct_checking", "Checking")]
        store.defaultAccountId = "acct_checking"
        let item = PendingImport(
            originBudgetId: store.currentBudgetId,
            amount: 9.99,
            sourceCurrencyCode: "USD",
            payee: "Coffee"
        )
        let approver = PendingImportApprover(store: store)

        _ = try await approver.approve(item)
        await #expect(throws: PendingImportApprover.ApproveError.alreadyApproved) {
            try await approver.approve(item)
        }
    }

    @Test func editedImportRetryIsIdempotentAndKeepsFinancialId() async throws {
        let (store, url) = try await makeWritableStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.accounts = [account("acct_checking", "Checking")]
        store.currencyCode = " usd "
        let item = PendingImport(
            originBudgetId: store.currentBudgetId,
            amount: 12.50,
            sourceCurrencyCode: " usd ",
            payee: "Coffee"
        )
        let form = BudgetStore.TransactionForm(
            accountId: "acct_checking",
            type: .expense,
            amount: "12.50",
            payeeName: "Coffee",
            transferToAccountId: nil,
            categoryId: nil,
            notes: "edited",
            date: Date(),
            cleared: false
        )
        let approver = PendingImportApprover(store: store)

        _ = try await approver.saveEdited(item, form: form)
        _ = try await approver.saveEdited(item, form: form)

        #expect(try databaseFinancialIds(at: url) == [PendingImportApprover.financialId(for: item)])
    }

    @Test func concurrentEditedSavesCreateOneRawTransactionRow() async throws {
        let (store, url) = try await makeWritableStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.accounts = [account("acct_checking", "Checking")]
        store.defaultAccountId = "acct_checking"
        let item = PendingImport(
            originBudgetId: store.currentBudgetId,
            amount: 12.50,
            sourceCurrencyCode: "USD",
            payee: "Coffee"
        )
        let form = BudgetStore.TransactionForm(
            accountId: "acct_checking", type: .expense, amount: "12.50",
            payeeName: "Coffee", transferToAccountId: nil, categoryId: nil,
            notes: "edited", date: Date(), cleared: false
        )
        let approver = PendingImportApprover(store: store)

        async let first = approver.saveEdited(item, form: form)
        async let second = approver.saveEdited(item, form: form)
        let firstResult = try await first
        let secondResult = try await second
        let results = [firstResult, secondResult]

        #expect(results.filter {
            if case .inserted = $0 { return true }
            return false
        }.count == 1)
        #expect(results.filter { $0 == .duplicate }.count == 1)
        #expect(try databaseRowCount(at: url) == 1)
    }

    @Test func ruleSuppressionIsReportedAndKeepsImportPending() async throws {
        let (store, url) = try await makeWritableStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.accounts = [account("acct_checking", "Checking")]
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO rules (id, conditions, actions, tombstone, conditions_op)
                VALUES ('delete-coffee',
                    '[{"op":"contains","field":"imported_description","value":"Coffee"}]',
                    '[{"op":"delete-transaction","value":null}]', 0, 'and')
                """)
        }
        let item = PendingImport(
            originBudgetId: store.currentBudgetId, amount: 12.50,
            sourceCurrencyCode: "USD", payee: "Coffee"
        )
        let form = BudgetStore.TransactionForm(
            accountId: "acct_checking", type: .expense, amount: "12.50",
            payeeName: "Coffee", transferToAccountId: nil, categoryId: nil,
            notes: "edited", date: Date(), cleared: false
        )

        let result = try await PendingImportApprover(store: store).saveEdited(item, form: form)
        #expect(result == .suppressedByRule)
        #expect(try databaseRowCount(at: url) == 0)
    }

    @Test func concurrentDirectApprovalsCreateOneRawTransactionRow() async throws {
        let (store, url) = try await makeWritableStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.accounts = [account("acct_checking", "Checking")]
        store.defaultAccountId = "acct_checking"
        let item = PendingImport(
            originBudgetId: store.currentBudgetId, amount: 12.50,
            sourceCurrencyCode: "USD", payee: "Coffee"
        )
        let approver = PendingImportApprover(store: store)

        async let first = approver.approve(item)
        async let second = approver.approve(item)
        let firstOutcome: Result<TransactionLogger.Result, any Error>
        do { firstOutcome = .success(try await first) }
        catch { firstOutcome = .failure(error) }
        let secondOutcome: Result<TransactionLogger.Result, any Error>
        do { secondOutcome = .success(try await second) }
        catch { secondOutcome = .failure(error) }
        let outcomes = [firstOutcome, secondOutcome]

        #expect(outcomes.filter {
            if case .success = $0 { return true }
            return false
        }.count == 1)
        #expect(outcomes.filter {
            if case let .failure(error) = $0,
               let approveError = error as? PendingImportApprover.ApproveError,
               approveError == .alreadyApproved { return true }
            return false
        }.count == 1)
        #expect(try databaseRowCount(at: url) == 1)
    }

    @Test func editedLegacyImportRequiresServiceConfirmation() async throws {
        let (store, url) = try await makeWritableStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.accounts = [account("acct_checking", "Checking")]
        let item = PendingImport(amount: 12.50, sourceCurrencyCode: "USD", payee: "Coffee")
        let form = BudgetStore.TransactionForm(
            accountId: "acct_checking", type: .expense, amount: "12.50",
            payeeName: "Coffee", transferToAccountId: nil, categoryId: nil,
            notes: "edited", date: Date(), cleared: false
        )

        await #expect(throws: PendingImportApprover.ApproveError.reviewConfirmationRequired) {
            try await PendingImportApprover(store: store).saveEdited(item, form: form)
        }
        #expect(try databaseRowCount(at: url) == 0)
    }

    @Test func editedForeignBudgetImportRequiresServiceConfirmation() async throws {
        let (store, url) = try await makeWritableStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.accounts = [account("acct_checking", "Checking")]
        let item = PendingImport(originBudgetId: "foreign-budget", amount: 12.50,
                                 sourceCurrencyCode: store.currencyCode, payee: "Coffee")
        let form = BudgetStore.TransactionForm(
            accountId: "acct_checking", type: .expense, amount: "12.50",
            payeeName: "Coffee", transferToAccountId: nil, categoryId: nil,
            notes: "edited", date: Date(), cleared: false
        )

        await #expect(throws: PendingImportApprover.ApproveError.reviewConfirmationRequired) {
            try await PendingImportApprover(store: store).saveEdited(item, form: form)
        }
        #expect(try databaseRowCount(at: url) == 0)
    }

    @Test func editedForeignCurrencyImportRequiresBothConfirmations() async throws {
        let (store, url) = try await makeWritableStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.accounts = [account("acct_checking", "Checking")]
        store.currencyCode = "USD"
        let item = PendingImport(originBudgetId: "foreign-budget", amount: 12.50,
                                 sourceCurrencyCode: "EUR", payee: "Coffee")
        let baseForm = BudgetStore.TransactionForm(
            accountId: "acct_checking", type: .expense, amount: "12.50",
            payeeName: "Coffee", transferToAccountId: nil, categoryId: nil,
            notes: "edited", date: Date(), cleared: false
        )

        await #expect(throws: PendingImportApprover.ApproveError.reviewConfirmationRequired) {
            try await PendingImportApprover(store: store).saveEdited(item, form: baseForm)
        }
        var confirmedForm = baseForm
        let requirements = item.reviewRequirements(
            activeBudgetId: store.currentBudgetId,
            budgetCurrency: store.currencyCode
        )
        confirmedForm.reviewConfirmations = Set(requirements.dropLast())
        await #expect(throws: PendingImportApprover.ApproveError.reviewConfirmationRequired) {
            try await PendingImportApprover(store: store).saveEdited(item, form: confirmedForm)
        }
        confirmedForm.reviewConfirmations = Set(requirements)
        let result = try await PendingImportApprover(store: store).saveEdited(item, form: confirmedForm)
        #expect(result == .inserted(item.id.uuidString))
        #expect(try databaseRowCount(at: url) == 1)
    }

    @Test func confirmedForeignBudgetImportSavesExactlyOneRow() async throws {
        let (store, url) = try await makeWritableStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.accounts = [account("acct_checking", "Checking")]
        let item = PendingImport(originBudgetId: "foreign-budget", amount: 12.50,
                                 sourceCurrencyCode: store.currencyCode, payee: "Coffee")
        let form = BudgetStore.TransactionForm(
            accountId: "acct_checking", type: .expense, amount: "12.50",
            payeeName: "Coffee", transferToAccountId: nil, categoryId: nil,
            notes: "edited", date: Date(), cleared: false,
            reviewConfirmations: Set(item.reviewRequirements(
                activeBudgetId: store.currentBudgetId,
                budgetCurrency: store.currencyCode
            ))
        )

        let result = try await PendingImportApprover(store: store).saveEdited(item, form: form)
        #expect(result == .inserted(item.id.uuidString))
        #expect(try databaseRowCount(at: url) == 1)
        #expect(try databaseFinancialIds(at: url) == [PendingImportApprover.financialId(for: item)])
    }

    @Test func editedCurrencyMismatchRequiresServiceConfirmation() async throws {
        let (store, url) = try await makeWritableStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.accounts = [account("acct_checking", "Checking")]
        store.currencyCode = "USD"
        let item = PendingImport(
            originBudgetId: store.currentBudgetId, amount: 12.50,
            sourceCurrencyCode: "EUR", payee: "Coffee"
        )
        let form = BudgetStore.TransactionForm(
            accountId: "acct_checking", type: .expense, amount: "12.50",
            payeeName: "Coffee", transferToAccountId: nil, categoryId: nil,
            notes: "edited", date: Date(), cleared: false
        )

        await #expect(throws: PendingImportApprover.ApproveError.reviewConfirmationRequired) {
            try await PendingImportApprover(store: store).saveEdited(item, form: form)
        }
        #expect(try databaseRowCount(at: url) == 0)
    }

    @Test func retryRepairsMessageLessFinancialIdRow() async throws {
        let (store, url) = try await makeWritableStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.accounts = [account("acct_checking", "Checking")]
        let item = PendingImport(originBudgetId: store.currentBudgetId, amount: 12.50,
                                 sourceCurrencyCode: "USD", payee: "Coffee")
        let form = BudgetStore.TransactionForm(
            accountId: "acct_checking", type: .expense, amount: "12.50",
            payeeName: "Coffee", transferToAccountId: nil, categoryId: nil,
            notes: "edited", date: Date(), cleared: false
        )
        let orphan = Transaction(
            id: item.id.uuidString, accountId: "acct_checking",
            date: Transaction.yyyymmdd(from: form.date), amount: -1250,
            payeeId: nil, payeeName: nil, categoryId: nil, categoryName: nil,
            notes: nil, cleared: false, reconciled: false, transferId: nil,
            isParent: false, parentId: nil, tombstone: false, sortOrder: nil,
            importedPayee: nil, financialId: PendingImportApprover.financialId(for: item)
        )
        try store.databaseForLogger?.insertTransaction(orphan)

        let result = try await PendingImportApprover(store: store).saveEdited(item, form: form)
        #expect(result == .inserted(item.id.uuidString))
        #expect(try databaseRowCount(at: url) == 1)
        #expect(try databaseMessageCount(for: item.id.uuidString, at: url) > 0)
    }

    @Test func confirmedCurrencyMismatchSavesExactlyOneRow() async throws {
        let (store, url) = try await makeWritableStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.accounts = [account("acct_checking", "Checking")]
        store.currencyCode = "USD"
        let item = PendingImport(originBudgetId: store.currentBudgetId, amount: 12.50,
                                 sourceCurrencyCode: "EUR", payee: "Coffee")
        let form = BudgetStore.TransactionForm(
            accountId: "acct_checking", type: .expense, amount: "12.50",
            payeeName: "Coffee", transferToAccountId: nil, categoryId: nil,
            notes: "edited", date: Date(), cleared: false,
            reviewConfirmations: Set(item.reviewRequirements(
                activeBudgetId: store.currentBudgetId,
                budgetCurrency: store.currencyCode
            ))
        )

        let result = try await PendingImportApprover(store: store).saveEdited(item, form: form)
        #expect(result == .inserted(item.id.uuidString))
        #expect(try databaseFinancialIds(at: url) == [PendingImportApprover.financialId(for: item)])
        #expect(try databaseRowCount(at: url) == 1)
    }

    @Test func confirmedLegacyImportSavesExactlyOneRow() async throws {
        let (store, url) = try await makeWritableStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.accounts = [account("acct_checking", "Checking")]
        let item = PendingImport(amount: 12.50, payee: "Coffee")
        var form = BudgetStore.TransactionForm(
            accountId: "acct_checking", type: .expense, amount: "12.50",
            payeeName: "Coffee", transferToAccountId: nil, categoryId: nil,
            notes: "edited", date: Date(), cleared: false
        )

        await #expect(throws: PendingImportApprover.ApproveError.reviewConfirmationRequired) {
            try await PendingImportApprover(store: store).saveEdited(item, form: form)
        }
        form.reviewConfirmations = Set(item.reviewRequirements(
            activeBudgetId: store.currentBudgetId,
            budgetCurrency: store.currencyCode
        ))
        let result = try await PendingImportApprover(store: store).saveEdited(item, form: form)
        #expect(result == .inserted(item.id.uuidString))
        #expect(try databaseRowCount(at: url) == 1)
        #expect(try databaseFinancialIds(at: url) == [PendingImportApprover.financialId(for: item)])
    }

    private func databaseFinancialIds(at url: URL) throws -> [String] {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db in
            try String.fetchAll(db, sql: "SELECT financial_id FROM transactions ORDER BY id")
        }
    }

    private func databaseRowCount(at url: URL) throws -> Int {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") ?? 0
        }
    }

    private func databaseMessageCount(for transactionId: String, at url: URL) throws -> Int {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messages_crdt
                WHERE dataset = 'transactions' AND row = ?
                """, arguments: [transactionId]) ?? 0
        }
    }
}

extension PendingImportApproverTests {
    @Test(arguments: ["tombstone = 1", "acct = 'other-account'"])
    func retryAfterDeletionOrAccountMoveIsAlreadyApproved(change: String) async throws {
        let (store, url) = try await makeWritableStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.accounts = [account("acct_checking", "Checking")]
        store.defaultAccountId = "acct_checking"
        let item = PendingImport(originBudgetId: store.currentBudgetId, amount: 9.99,
                                 sourceCurrencyCode: "USD", payee: "Coffee")
        let approver = PendingImportApprover(store: store)
        _ = try await approver.approve(item)
        let queue = try DatabaseQueue(path: url.path)
        try await queue.write { db in
            try db.execute(sql: "UPDATE transactions SET \(change) WHERE id = ?", arguments: [item.id.uuidString])
        }
        await #expect(throws: PendingImportApprover.ApproveError.alreadyApproved) {
            try await approver.approve(item)
        }
    }
}
