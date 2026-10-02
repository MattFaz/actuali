import Combine
import Foundation
import GRDB
import Testing
@testable import Actuali

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
                try db.execute(sql: TestSchema.upstream)
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
        return try StoredZip.archive([
            (name: "db.sqlite", data: Data(contentsOf: dbURL)),
            (name: "metadata.json", data: JSONEncoder().encode(metadata)),
        ])
    }

    /// Store wired to a disposable Budgets directory and a stubbed transport
    /// that answers the budget download with `zip` and fails every other
    /// request, so `downloadBudget` exercises the real download → import →
    /// load → sync path without a server while the sync leg that follows
    /// fails fast and locally.
    private func makeStore(zip: Data, root rootDirectory: URL) async throws -> BudgetStore {
        let session = StubTransport.session { request in
            guard request.url?.path.contains("download-user-file") == true else {
                throw URLError(.cannotConnectToHost)
            }
            return StubTransport.Response(contentType: "application/zip", body: zip)
        }
        let serverClient = ActualServerClient(session: session)
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
                forKey: "transactionNotificationWatermark.\(budgetId)"
            )
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
        let store = try await makeStore(zip: makeBudgetZip(budgetId: budgetId), root: root)

        await store.downloadBudget(Self.remoteBudget)

        // The budget opened...
        #expect(store.error == nil)
        #expect(store.accounts.map(\.name) == ["Checking"])
        // ...and its first sync ran as part of opening it, rather than waiting
        // for a pull-to-refresh or a foreground transition.
        #expect(store.syncStatus.lastSyncTime != nil)
    }

    /// The other half of the report — "no clear indication that a sync is still
    /// in progress". The flag the banner reads has to go up while the first
    /// sync is in flight and come back down when it lands.
    @Test func initialSyncIsFlaggedWhileItRunsAndClearedAfterwards() async throws {
        let savedBudgetId = UserDefaults.standard.string(forKey: "currentBudgetId")
        let root = try makeRootDirectory()
        let budgetId = "test-initial-sync-\(UUID().uuidString)"
        defer { cleanUp(root: root, budgetId: budgetId, savedBudgetId: savedBudgetId) }
        let store = try await makeStore(zip: makeBudgetZip(budgetId: budgetId), root: root)

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

    /// The initial sync's catch-up can span weeks of history, and the downloaded
    /// file's messages_crdt rowids restart from whatever the uploading client
    /// had. A watermark left behind by a previous copy of this budget therefore
    /// points at unrelated messages — high enough to pass the detector's
    /// `watermark <= maxId` guard, low enough to announce that whole catch-up as
    /// new transactions. Opening the file has to drop it.
    @Test func freshDownloadDoesNotKeepAPreviousCopysNotificationWatermark() async throws {
        let savedBudgetId = UserDefaults.standard.string(forKey: "currentBudgetId")
        let root = try makeRootDirectory()
        let budgetId = "test-initial-sync-\(UUID().uuidString)"
        defer { cleanUp(root: root, budgetId: budgetId, savedBudgetId: savedBudgetId) }
        let key = "transactionNotificationWatermark.\(budgetId)"
        UserDefaults.standard.set(NSNumber(value: Int64(500)), forKey: key)
        let store = try await makeStore(zip: makeBudgetZip(budgetId: budgetId), root: root)

        await store.downloadBudget(Self.remoteBudget)

        #expect(store.error == nil)
        // Either removed, or re-baselined against the new file by the detector
        // that ran during the initial sync. What matters is that the stale value
        // is gone.
        let watermark = (UserDefaults.standard.object(forKey: key) as? NSNumber)?.int64Value
        #expect(watermark != 500)
    }
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

            payload += le32(0x04034b50) // local file header
            payload += le16(20) // version needed
            payload += le16(0) // flags
            payload += le16(0) // method: stored
            payload += le16(0) // mod time
            payload += le16(0x21) // mod date: 1980-01-01
            payload += le32(crc)
            payload += le32(size) // compressed size
            payload += le32(size) // uncompressed size
            payload += le16(UInt16(name.count))
            payload += le16(0) // extra field length
            payload += name
            payload += entry.data

            central += le32(0x02014b50) // central directory header
            central += le16(20) // version made by
            central += le16(20) // version needed
            central += le16(0) // flags
            central += le16(0) // method: stored
            central += le16(0) // mod time
            central += le16(0x21) // mod date
            central += le32(crc)
            central += le32(size)
            central += le32(size)
            central += le16(UInt16(name.count))
            central += le16(0) // extra field length
            central += le16(0) // comment length
            central += le16(0) // disk number start
            central += le16(0) // internal attributes
            central += le32(0) // external attributes
            central += le32(offset)
            central += name
        }

        let centralOffset = UInt32(payload.count)
        var output = payload
        output += central
        output += le32(0x06054b50) // end of central directory
        output += le16(0) // this disk
        output += le16(0) // disk with central directory
        output += le16(UInt16(entries.count))
        output += le16(UInt16(entries.count))
        output += le32(UInt32(central.count))
        output += le32(centralOffset)
        output += le16(0) // comment length
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
            UInt8((value >> 24) & 0xff),
        ])
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                // Branch-free: subtract the low bit from zero to get the mask.
                crc = (crc >> 1) ^ (0xedb88320 & (0 &- (crc & 1)))
            }
        }
        return crc ^ 0xffffffff
    }
}
