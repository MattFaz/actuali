import Foundation
import GRDB
import Synchronization
@testable import Actuali

// MARK: - Budget files

/// Upstream table DDL for suites that hand-build a budget file. Each table is
/// the union of the columns those suites need. Which tables a suite creates
/// still matters (`BudgetDatabase` probes for notes, preferences, rules,
/// schedules, tags, zero_budget_months and the two budget tables), so suites
/// pick tables rather than getting everything.
enum TestSchema {
    static let accounts = """
    CREATE TABLE accounts (
        id TEXT PRIMARY KEY, name TEXT, type TEXT, offbudget INTEGER DEFAULT 0,
        closed INTEGER DEFAULT 0, sort_order REAL, tombstone INTEGER DEFAULT 0,
        account_id TEXT, account_sync_source TEXT, bank TEXT, balance_current INTEGER,
        balance_available INTEGER, balance_limit INTEGER, mask TEXT, official_name TEXT,
        subtype TEXT, bank_sync_status TEXT
    )
    """
    static let transactions = """
    CREATE TABLE transactions (
        id TEXT PRIMARY KEY, starting_balance_flag INTEGER DEFAULT 0,
        isParent INTEGER DEFAULT 0, isChild INTEGER DEFAULT 0, acct TEXT, category TEXT,
        amount INTEGER, description TEXT, notes TEXT, date INTEGER,
        imported_description TEXT, financial_id TEXT, transferred_id TEXT, schedule TEXT,
        sort_order REAL, tombstone INTEGER DEFAULT 0, cleared INTEGER DEFAULT 0,
        reconciled INTEGER DEFAULT 0, parent_id TEXT, type TEXT, location TEXT, error TEXT
    )
    """
    static let payees = """
    CREATE TABLE payees (
        id TEXT PRIMARY KEY, name TEXT, category TEXT, transfer_acct TEXT,
        tombstone INTEGER DEFAULT 0
    )
    """
    static let payeeMapping = "CREATE TABLE payee_mapping (id TEXT PRIMARY KEY, targetId TEXT)"
    static let categories = """
    CREATE TABLE categories (
        id TEXT PRIMARY KEY, name TEXT, is_income INTEGER DEFAULT 0, cat_group TEXT,
        sort_order REAL, hidden INTEGER DEFAULT 0, tombstone INTEGER DEFAULT 0
    )
    """
    static let categoryGroups = """
    CREATE TABLE category_groups (
        id TEXT PRIMARY KEY, name TEXT, is_income INTEGER DEFAULT 0, sort_order REAL,
        hidden INTEGER DEFAULT 0, tombstone INTEGER DEFAULT 0
    )
    """
    static let categoryMapping = "CREATE TABLE category_mapping (id TEXT PRIMARY KEY, transferId TEXT)"
    static let messagesCrdt = """
    CREATE TABLE messages_crdt (
        id INTEGER PRIMARY KEY, timestamp TEXT NOT NULL UNIQUE, dataset TEXT NOT NULL,
        row TEXT NOT NULL, column TEXT NOT NULL, value BLOB NOT NULL
    )
    """
    static let messagesClock = "CREATE TABLE messages_clock (id INTEGER PRIMARY KEY, clock TEXT)"
    static let preferences = "CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT)"
    static let notes = "CREATE TABLE notes (id TEXT PRIMARY KEY, note TEXT)"
    static let zeroBudgets = """
    CREATE TABLE zero_budgets (
        id TEXT PRIMARY KEY, month INTEGER, category TEXT, amount INTEGER DEFAULT 0,
        carryover INTEGER DEFAULT 0
    )
    """
    static let reflectBudgets = """
    CREATE TABLE reflect_budgets (
        id TEXT PRIMARY KEY, month INTEGER, category TEXT, amount INTEGER DEFAULT 0,
        carryover INTEGER DEFAULT 0
    )
    """
    static let zeroBudgetMonths = """
    CREATE TABLE zero_budget_months (id TEXT PRIMARY KEY, buffered INTEGER DEFAULT 0)
    """
    static let rules = """
    CREATE TABLE rules (
        id TEXT PRIMARY KEY, stage TEXT, conditions TEXT, actions TEXT,
        tombstone INTEGER DEFAULT 0, conditions_op TEXT DEFAULT 'and'
    )
    """
    static let schedules = """
    CREATE TABLE schedules (
        id TEXT PRIMARY KEY, name TEXT, rule TEXT, active INTEGER DEFAULT 0,
        completed INTEGER DEFAULT 0, posts_transaction INTEGER DEFAULT 0,
        tombstone INTEGER DEFAULT 0
    )
    """
    static let schedulesNextDate = """
    CREATE TABLE schedules_next_date (
        id TEXT PRIMARY KEY, schedule_id TEXT, local_next_date INTEGER,
        local_next_date_ts INTEGER, base_next_date INTEGER, base_next_date_ts INTEGER
    )
    """
    static let tags = """
    CREATE TABLE tags (
        id TEXT PRIMARY KEY, tag TEXT, color TEXT, description TEXT,
        hidden BOOLEAN DEFAULT 0, tombstone INTEGER DEFAULT 0
    )
    """

    /// The tables every transaction-writing suite needs.
    static let core = [
        accounts, transactions, payees, payeeMapping, categories, categoryGroups,
        categoryMapping, messagesCrdt,
    ]

    /// A freshly downloaded upstream file: the tables `loadLocalBudget` opens,
    /// with upstream's own column types and the bookkeeping tables.
    static let upstream = """
    CREATE TABLE accounts (
        id TEXT PRIMARY KEY, name TEXT, type TEXT, offbudget INTEGER DEFAULT 0,
        closed INTEGER DEFAULT 0, tombstone INTEGER DEFAULT 0, sort_order REAL,
        account_id TEXT, balance_current INTEGER, balance_available INTEGER,
        balance_limit INTEGER, mask TEXT, official_name TEXT, subtype TEXT, bank TEXT
    );
    CREATE TABLE transactions (
        id TEXT PRIMARY KEY, isParent INTEGER DEFAULT 0, isChild INTEGER DEFAULT 0,
        acct TEXT, category TEXT, amount INTEGER, description TEXT, notes TEXT,
        date INTEGER, financial_id TEXT, type TEXT, location TEXT, error TEXT,
        imported_description TEXT, starting_balance_flag INTEGER DEFAULT 0,
        transferred_id TEXT, sort_order REAL, tombstone INTEGER DEFAULT 0,
        cleared INTEGER DEFAULT 0, reconciled INTEGER DEFAULT 0, parent_id TEXT,
        schedule TEXT
    );
    CREATE TABLE categories (
        id TEXT PRIMARY KEY, name TEXT, is_income INTEGER DEFAULT 0, cat_group TEXT,
        sort_order REAL, tombstone INTEGER DEFAULT 0, hidden BOOLEAN NOT NULL DEFAULT 0
    );
    CREATE TABLE category_groups (
        id TEXT PRIMARY KEY, name TEXT UNIQUE, is_income INTEGER DEFAULT 0,
        sort_order REAL, tombstone INTEGER DEFAULT 0, hidden BOOLEAN NOT NULL DEFAULT 0
    );
    CREATE TABLE payees (
        id TEXT PRIMARY KEY, name TEXT, category TEXT, tombstone INTEGER DEFAULT 0,
        transfer_acct TEXT
    );
    CREATE TABLE payee_mapping (id TEXT PRIMARY KEY, targetId TEXT);
    CREATE TABLE category_mapping (id TEXT PRIMARY KEY, transferId TEXT);
    CREATE TABLE zero_budgets (
        id TEXT PRIMARY KEY, month INTEGER, category TEXT, amount INTEGER DEFAULT 0,
        carryover INTEGER DEFAULT 0
    );
    CREATE TABLE preferences (id TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE messages_crdt (
        id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp TEXT NOT NULL UNIQUE,
        dataset TEXT NOT NULL, row TEXT NOT NULL, column TEXT NOT NULL, value BLOB NOT NULL
    );
    CREATE TABLE messages_clock (id INTEGER PRIMARY KEY, clock TEXT);
    CREATE TABLE db_version (version TEXT PRIMARY KEY);
    CREATE TABLE __migrations__ (id INT PRIMARY KEY NOT NULL);
    """
}

/// A fresh temp-file budget built from `sql` (DDL and seed rows alike), opened
/// through `BudgetDatabase` so its migrations run as they do on device.
///
/// `@concurrent` because most callers are `@MainActor` suites, and the
/// synchronous build-and-migrate would otherwise run on the one main thread
/// every such suite shares — which is what bounds the whole run's wall clock.
@concurrent
func makeTestDatabase(_ sql: String...) async throws -> (BudgetDatabase, URL) {
    try await makeTestDatabase(sql)
}

@concurrent
func makeTestDatabase(_ sql: [String]) async throws -> (BudgetDatabase, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("test-\(UUID().uuidString).sqlite")
    try await DatabaseQueue(path: url.path).write { db in
        for statement in sql where !statement.isEmpty {
            try db.execute(sql: statement)
        }
    }
    return try (BudgetDatabase(path: url), url)
}

func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// Every CRDT message a write produced, oldest first.
func messageRows(path: URL) throws -> [Row] {
    try DatabaseQueue(path: path.path).read { db in
        try Row.fetchAll(db, sql: "SELECT * FROM messages_crdt ORDER BY timestamp")
    }
}

// MARK: - Stores

/// A sync client over `database` with no server configured, so writes queue
/// locally and never push.
func makeTestSyncClient(database: BudgetDatabase) async throws -> SyncClient {
    let syncClient = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
    try await syncClient.configure(database: database, fileId: "test-file", groupId: "test-group")
    return syncClient
}

/// A preview store writing through `database`, with a sync client that has
/// no server configured (so writes queue locally and never push).
@MainActor
func makeTestStore(database: BudgetDatabase) async throws -> BudgetStore {
    let store = BudgetStore.previewInstance()
    let syncClient = try await makeTestSyncClient(database: database)
    store.configureForTesting(database: database, syncClient: syncClient)
    return store
}

/// A preview store over its own budgets directory, for suites that go through
/// `loadLocalBudget`. Remove the returned root when done.
@MainActor
func makeFileBackedStore() -> (BudgetStore, BudgetFileManager, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("budgets-\(UUID().uuidString)", isDirectory: true)
    let manager = BudgetFileManager(rootDirectoryForTesting: root)
    let store = BudgetStore.previewInstance()
    store.setFileManagerForTesting(manager)
    return (store, manager, root)
}

/// Writes a budget `loadLocalBudget(id)` can open: the database built from
/// `sql` plus its metadata.
func seedBudget(id: String, in manager: BudgetFileManager, sql: String = TestSchema.upstream) throws {
    try FileManager.default.createDirectory(
        at: manager.budgetDirectory(for: id), withIntermediateDirectories: true
    )
    try DatabaseQueue(path: manager.databasePath(for: id).path).write { db in
        try db.execute(sql: sql)
    }
    try JSONEncoder().encode(BudgetMetadata(
        id: id, budgetName: "Seed", cloudFileId: "cf-1", groupId: "group-1",
        resetClock: nil, lastUploaded: nil, encryptKeyId: nil
    )).write(to: manager.metadataPath(for: id))
}

// MARK: - Concurrency

/// A one-shot latch for forcing an interleaving: `wait()` suspends until
/// `open()`, and returns at once if already open.
final class Gate: Sendable {
    private let state = Mutex<(isOpen: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { state in
                if !state.isOpen {
                    state.waiters.append(continuation)
                }
                return state.isOpen
            }
            if isOpen {
                continuation.resume()
            }
        }
    }
}

// MARK: - Network

/// A `URLProtocol` stub routed per session: each `session(_:)` gets its own
/// handler, keyed by a header, so suites can stub the network concurrently
/// instead of serializing on shared static state.
final class StubTransport: URLProtocol {
    struct Response: Sendable {
        var status = 200
        var contentType: String?
        var body = Data()
    }

    /// Runs on the loading thread, so it may block (e.g. on a test gate).
    /// Throwing fails the request with that error.
    typealias Handler = @Sendable (URLRequest) throws -> Response

    private static let header = "X-Stub-Transport"
    // ponytail: handlers are never removed; one closure per test session is
    // noise for a test process, prune in `stopLoading` if that changes.
    private static let handlers = Mutex<[String: Handler]>([:])

    static func session(_ handler: @escaping Handler) -> URLSession {
        let id = UUID().uuidString
        handlers.withLock { $0[id] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubTransport.self]
        configuration.httpAdditionalHeaders = [header: id]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: Self.header) ?? ""
        guard let handler = Self.handlers.withLock({ $0[id] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let stub = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.status,
                httpVersion: "HTTP/1.1",
                headerFields: stub.contentType.map { ["Content-Type": $0] }
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension URLRequest {
    /// The body as sent: URLSession hands protocols a stream, not `httpBody`.
    var bodyData: Data {
        if let httpBody {
            return httpBody
        }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
