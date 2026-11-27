import Combine
import CryptoKit
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
        try await makeStore(root: rootDirectory) { request in
            guard request.url?.path.contains("download-user-file") == true else {
                throw URLError(.cannotConnectToHost)
            }
            return StubTransport.Response(contentType: "application/zip", body: zip)
        }
    }

    private func makeStore(
        root rootDirectory: URL,
        respond: @escaping StubTransport.Handler
    ) async throws -> BudgetStore {
        let session = StubTransport.session(respond)
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

    private struct KeyFixture: Codable {
        let password: String
        let salt: String
        let keyId: String
        let derivedKeyBase64: String
        let test: String
    }

    private final class BundleToken {}

    /// Unlocking an encrypted budget held the password sheet until the initial
    /// sync finished, so a slow or stalled sync froze it with every control
    /// disabled. Unlocking is done once the budget is open; the sync follows.
    @Test func unlockingReturnsOnceTheBudgetIsOpenWithoutWaitingForTheInitialSync() async throws {
        let savedBudgetId = UserDefaults.standard.string(forKey: "currentBudgetId")
        let root = try makeRootDirectory()
        let budgetId = "test-initial-sync-\(UUID().uuidString)"
        let remoteBudget = BudgetStore.RemoteBudget(
            id: "cloud-file-\(UUID().uuidString)", name: "Test Budget", groupId: "group-1", isEncrypted: true
        )
        defer {
            try? EncryptionKeyManager.remove(fileId: remoteBudget.id)
            cleanUp(root: root, budgetId: budgetId, savedBudgetId: savedBudgetId)
        }

        let fixtureURL = try #require(
            Bundle(for: BundleToken.self).url(forResource: "encryption-key-fixture", withExtension: "json")
        )
        let fixture = try JSONDecoder().decode(KeyFixture.self, from: Data(contentsOf: fixtureURL))
        let key = try SymmetricKey(data: #require(Data(base64Encoded: fixture.derivedKeyBase64)))
        let encrypted = try SyncEncryption.encrypt(makeBudgetZip(budgetId: budgetId), using: key)
        let keyInfo = try JSONEncoder().encode(KeyInfoResponse(
            status: "ok",
            data: .init(id: fixture.keyId, salt: fixture.salt, test: fixture.test)
        ))
        let fileInfo = try JSONEncoder().encode(FileInfoResponse(
            status: "ok",
            data: .init(
                fileId: remoteBudget.id,
                groupId: remoteBudget.groupId,
                name: remoteBudget.name,
                deleted: 0,
                encryptMeta: .init(
                    keyId: fixture.keyId,
                    algorithm: "aes-256-gcm",
                    iv: encrypted.iv.base64EncodedString(),
                    authTag: encrypted.authTag.base64EncodedString()
                )
            )
        ))
        let ciphertext = encrypted.data
        let store = try await makeStore(root: root) { request in
            let path = request.url?.path ?? ""
            if path.contains("user-get-key") {
                return StubTransport.Response(contentType: "application/json", body: keyInfo)
            }
            if path.contains("get-user-file-info") {
                return StubTransport.Response(contentType: "application/json", body: fileInfo)
            }
            if path.contains("download-user-file") {
                return StubTransport.Response(contentType: "application/zip", body: ciphertext)
            }
            throw URLError(.cannotConnectToHost)
        }

        let failure = await store.unlockAndOpen(remoteBudget, password: fixture.password)

        #expect(failure == nil)
        #expect(store.accounts.map(\.name) == ["Checking"])
        #expect(store.isInitialSyncing, "unlocking waited for the initial sync")

        // The sync still runs; let it land before the budget directory goes.
        while store.isInitialSyncing {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.syncStatus.lastSyncTime != nil)
    }

    /// The encryption password was reset elsewhere, so the stored key is for
    /// an older key id. The download must stop, drop the stale key and leave
    /// the budget asking for its password again.
    @Test func downloadWithAStaleKeyDropsItAndAsksForThePasswordAgain() async throws {
        let savedBudgetId = UserDefaults.standard.string(forKey: "currentBudgetId")
        let root = try makeRootDirectory()
        let remoteBudget = BudgetStore.RemoteBudget(
            id: "cloud-file-\(UUID().uuidString)", name: "Test Budget", groupId: "group-1", isEncrypted: true
        )
        defer {
            try? EncryptionKeyManager.remove(fileId: remoteBudget.id)
            cleanUp(root: root, budgetId: nil, savedBudgetId: savedBudgetId)
        }

        try EncryptionKeyManager.store(
            LoadedKey(keyId: "old-key", key: SymmetricKey(size: .bits256)), fileId: remoteBudget.id
        )
        let fileInfo = try JSONEncoder().encode(FileInfoResponse(
            status: "ok",
            data: .init(
                fileId: remoteBudget.id,
                groupId: remoteBudget.groupId,
                name: remoteBudget.name,
                deleted: 0,
                encryptMeta: .init(keyId: "new-key", algorithm: "aes-256-gcm", iv: "aXY=", authTag: "dGFn")
            )
        ))
        let store = try await makeStore(root: root) { request in
            let path = request.url?.path ?? ""
            if path.contains("get-user-file-info") {
                return StubTransport.Response(contentType: "application/json", body: fileInfo)
            }
            if path.contains("download-user-file") {
                return StubTransport.Response(contentType: "application/zip", body: Data("ciphertext".utf8))
            }
            throw URLError(.cannotConnectToHost)
        }

        await store.downloadBudget(remoteBudget)

        #expect(store.error == "This budget's encryption key has changed. Re-enter the password.")
        #expect(store.accounts.isEmpty)
        #expect(store.isInitialSyncing == false)
        #expect(EncryptionKeyManager.load(fileId: remoteBudget.id) == nil)
        // With the key gone, picking the budget hands it back for its password.
        #expect(store.openRemoteBudget(remoteBudget)?.id == remoteBudget.id)
    }

    /// A key stored for a budget that then failed to download used to stay in
    /// the Keychain, so picking the budget again skipped the password sheet
    /// and silently retried the download.
    @Test func failedUnlockDownloadDoesNotLeaveTheKeyBehind() async throws {
        let savedBudgetId = UserDefaults.standard.string(forKey: "currentBudgetId")
        let root = try makeRootDirectory()
        let remoteBudget = BudgetStore.RemoteBudget(
            id: "cloud-file-\(UUID().uuidString)", name: "Test Budget", groupId: "group-1", isEncrypted: true
        )
        defer {
            try? EncryptionKeyManager.remove(fileId: remoteBudget.id)
            cleanUp(root: root, budgetId: nil, savedBudgetId: savedBudgetId)
        }

        let fixtureURL = try #require(
            Bundle(for: BundleToken.self).url(forResource: "encryption-key-fixture", withExtension: "json")
        )
        let fixture = try JSONDecoder().decode(KeyFixture.self, from: Data(contentsOf: fixtureURL))
        let keyInfo = try JSONEncoder().encode(KeyInfoResponse(
            status: "ok",
            data: .init(id: fixture.keyId, salt: fixture.salt, test: fixture.test)
        ))
        // The password checks out, then the download itself fails.
        let store = try await makeStore(root: root) { request in
            guard request.url?.path.contains("user-get-key") == true else {
                throw URLError(.cannotConnectToHost)
            }
            return StubTransport.Response(contentType: "application/json", body: keyInfo)
        }

        let failure = await store.unlockAndOpen(remoteBudget, password: fixture.password)

        #expect(failure != nil)
        #expect(EncryptionKeyManager.load(fileId: remoteBudget.id) == nil)
        #expect(store.isInitialSyncing == false)
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
