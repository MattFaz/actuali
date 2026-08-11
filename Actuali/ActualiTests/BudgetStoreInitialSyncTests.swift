import Combine
import Foundation
import GRDB
import Testing
@testable import Actuali

/// Answers the budget download with a canned ZIP and fails every other request,
/// so `downloadBudget` can run end to end without a server while the sync leg
/// that follows it fails fast and locally.
private final class BudgetDownloadTransport: URLProtocol {
    nonisolated(unsafe) static var zipData = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard request.url?.path.contains("download-user-file") == true else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/zip"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.zipData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// GH #126: a first-time setup downloaded the budget, showed the snapshot's
/// balances, and then just sat there — nothing synced until the user
/// pull-to-refreshed or backgrounded and reopened the app, and nothing on
/// screen said the figures weren't final. The server snapshot in that ZIP can
/// trail the server's message log by hours or days, so those numbers read as
/// current when they weren't ("had me scared for a second").
@Suite(.serialized)
@MainActor
struct BudgetStoreInitialSyncTests {

    // MARK: - Fixtures

    /// A budget ZIP shaped like the one `/sync/download-user-file` returns:
    /// `db.sqlite` on the upstream schema plus `metadata.json`.
    private func makeBudgetZip(budgetId: String) throws -> Data {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        // Scoped so the connection is released before the bytes are read.
        do {
            let queue = try DatabaseQueue(path: dbURL.path)
            try queue.write { db in
                try db.execute(sql: Self.upstreamSchema)
                try db.execute(sql: """
                    INSERT INTO accounts (id, name, type, sort_order)
                    VALUES ('acct-1', 'Checking', 'checking', 1.0);
                    """)
            }
        }

        let metadata = BudgetMetadata(
            id: budgetId,
            budgetName: "Test Budget",
            cloudFileId: nil,
            groupId: nil,
            resetClock: nil,
            lastUploaded: nil,
            encryptKeyId: nil
        )
        return StoredZip.archive([
            (name: "db.sqlite", data: try Data(contentsOf: dbURL)),
            (name: "metadata.json", data: try JSONEncoder().encode(metadata))
        ])
    }

    /// Store wired to a disposable Budgets directory and a stubbed transport,
    /// so `downloadBudget` exercises the real download → import → load → sync
    /// path without touching the shared app-support directory or a server.
    private func makeStore(zip: Data, root rootDirectory: URL) async throws -> BudgetStore {
        BudgetDownloadTransport.zipData = zip
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BudgetDownloadTransport.self]
        let serverClient = ActualServerClient(session: URLSession(configuration: config))
        try await serverClient.configure(serverURL: "https://budget.example.com")
        await serverClient.setToken("test-token")

        let store = BudgetStore.previewInstance()
        store.setServerClientForTesting(serverClient)
        store.setFileManagerForTesting(BudgetFileManager(rootDirectoryForTesting: rootDirectory))
        return store
    }

    private func makeRootDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("budgets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `currentBudgetId`'s didSet and the notification watermark both persist
    /// to UserDefaults; restore them so tests leave the host app's defaults as
    /// they found them.
    private func cleanUp(root: URL, budgetId: String?, savedBudgetId: String?) {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.set(savedBudgetId, forKey: "currentBudgetId")
        if let budgetId {
            UserDefaults.standard.removeObject(
                forKey: "transactionNotificationWatermark.\(budgetId)")
        }
    }

    private static let remoteBudget = BudgetStore.RemoteBudget(
        id: "cloud-file-1", name: "Test Budget", groupId: "group-1", isEncrypted: false
    )

    // MARK: - Tests

    /// The bug: nothing kicked off a sync after the download, so the snapshot's
    /// figures stayed on screen until some other event happened to sync.
    @Test func freshDownloadSyncsTheSnapshotImmediately() async throws {
        let savedBudgetId = UserDefaults.standard.string(forKey: "currentBudgetId")
        let root = try makeRootDirectory()
        let budgetId = "test-initial-sync-\(UUID().uuidString)"
        defer { cleanUp(root: root, budgetId: budgetId, savedBudgetId: savedBudgetId) }
        let store = try await makeStore(zip: try makeBudgetZip(budgetId: budgetId), root: root)

        await store.downloadBudget(Self.remoteBudget)

        // The budget opened...
        #expect(store.error == nil)
        #expect(store.accounts.map(\.name) == ["Checking"])
        // ...and its first sync ran as part of opening it, rather than waiting
        // for a pull-to-refresh or a foreground transition.
        #expect(store.lastSyncTime != nil)
    }

    /// The other half of the report — "no clear indication that a sync is still
    /// in progress". The flag the banner reads has to go up while the first
    /// sync is in flight and come back down when it lands.
    @Test func initialSyncIsFlaggedWhileItRunsAndClearedAfterwards() async throws {
        let savedBudgetId = UserDefaults.standard.string(forKey: "currentBudgetId")
        let root = try makeRootDirectory()
        let budgetId = "test-initial-sync-\(UUID().uuidString)"
        defer { cleanUp(root: root, budgetId: budgetId, savedBudgetId: savedBudgetId) }
        let store = try await makeStore(zip: try makeBudgetZip(budgetId: budgetId), root: root)

        var observed: [Bool] = []
        let subscription = store.$isInitialSyncing.sink { observed.append($0) }
        defer { subscription.cancel() }

        #expect(store.isInitialSyncing == false)
        await store.downloadBudget(Self.remoteBudget)

        #expect(observed.contains(true), "the syncing state was never published")
        #expect(store.isInitialSyncing == false, "the syncing state never cleared")
    }

    /// A download that never lands leaves nothing to catch up, so the banner
    /// must not be left hanging over an unchanged budget.
    @Test func failedDownloadDoesNotLeaveTheSyncingStateStuckOn() async throws {
        let savedBudgetId = UserDefaults.standard.string(forKey: "currentBudgetId")
        let root = try makeRootDirectory()
        defer { cleanUp(root: root, budgetId: nil, savedBudgetId: savedBudgetId) }
        // Not a ZIP: the import fails and downloadBudget surfaces the error.
        let store = try await makeStore(zip: Data("not a zip".utf8), root: root)

        await store.downloadBudget(Self.remoteBudget)

        #expect(store.error != nil)
        #expect(store.isInitialSyncing == false)
    }

    // MARK: - Upstream schema

    /// The tables `loadLocalBudget` reads and `SyncClient.configure` needs,
    /// matching the schema an Actual server ships in a budget ZIP.
    private static let upstreamSchema = """
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

/// Builds an uncompressed ZIP in memory. Hand-rolled because ZIPFoundation is
/// linked into the app target only; stored entries are the simplest thing it
/// will read back, and that read is what these tests are exercising.
private enum StoredZip {
    static func archive(_ entries: [(name: String, data: Data)]) -> Data {
        var payload = Data()
        var central = Data()

        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(payload.count)

            payload += le32(0x0403_4b50)      // local file header
            payload += le16(20)               // version needed
            payload += le16(0)                // flags
            payload += le16(0)                // method: stored
            payload += le16(0)                // mod time
            payload += le16(0x21)             // mod date: 1980-01-01
            payload += le32(crc)
            payload += le32(size)             // compressed size
            payload += le32(size)             // uncompressed size
            payload += le16(UInt16(name.count))
            payload += le16(0)                // extra field length
            payload += name
            payload += entry.data

            central += le32(0x0201_4b50)      // central directory header
            central += le16(20)               // version made by
            central += le16(20)               // version needed
            central += le16(0)                // flags
            central += le16(0)                // method: stored
            central += le16(0)                // mod time
            central += le16(0x21)             // mod date
            central += le32(crc)
            central += le32(size)
            central += le32(size)
            central += le16(UInt16(name.count))
            central += le16(0)                // extra field length
            central += le16(0)                // comment length
            central += le16(0)                // disk number start
            central += le16(0)                // internal attributes
            central += le32(0)                // external attributes
            central += le32(offset)
            central += name
        }

        let centralOffset = UInt32(payload.count)
        var output = payload
        output += central
        output += le32(0x0605_4b50)           // end of central directory
        output += le16(0)                     // this disk
        output += le16(0)                     // disk with central directory
        output += le16(UInt16(entries.count))
        output += le16(UInt16(entries.count))
        output += le32(UInt32(central.count))
        output += le32(centralOffset)
        output += le16(0)                     // comment length
        return output
    }

    private static func le16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xff), UInt8(value >> 8)])
    }

    private static func le32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff)
        ])
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                // Branch-free: subtract the low bit from zero to get the mask.
                crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1)))
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
