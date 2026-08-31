import CryptoKit
import Foundation
import Testing
@testable import Actuali

/// Answers /sync/delete-user-file with a preset status so deleteServerBudget's
/// orchestration (server call, then local cleanup) can run offline.
private final class DeleteBudgetTransport: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var requestedPaths: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestedPaths.append(request.url?.path ?? "")
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"status":"ok"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Coverage for the two budget-deletion scopes (GH #390): "remove from this
/// device" deletes the local directory and device-side state while leaving the
/// server file alone, and "delete from server" additionally soft-deletes the
/// server file. Deleting the open budget must close it and return the app to
/// the "select a budget" empty state instead of leaving a dangling session.
@MainActor
@Suite(.serialized)
struct BudgetStoreDeleteBudgetTests {

    /// Store + file manager rooted in a unique temp directory, so parallel
    /// suites that create real budgets in the shared directory stay unaffected.
    private func makeIsolatedStore() throws -> (BudgetStore, BudgetFileManager) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("delete-budget-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = BudgetFileManager(rootDirectoryForTesting: root)
        let store = BudgetStore.previewInstance()
        store.setFileManagerForTesting(manager)
        return (store, manager)
    }

    /// On-disk budget with the metadata.json that listLocalBudgets() keys on,
    /// plus a backup archive to prove directory removal takes backups/ along.
    private func seedBudget(
        id: String,
        cloudFileId: String,
        encryptKeyId: String? = nil,
        in manager: BudgetFileManager
    ) throws {
        let dir = manager.budgetDirectory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("stub".utf8).write(to: manager.databasePath(for: id))
        try Data("backup".utf8).write(to: manager.backupPath(for: id, name: "2026-01-01_00-00-00.zip"))
        let metadata = BudgetMetadata(
            id: id,
            budgetName: "Test Budget",
            cloudFileId: cloudFileId,
            groupId: nil,
            resetClock: nil,
            lastUploaded: nil,
            encryptKeyId: encryptKeyId
        )
        try JSONEncoder().encode(metadata).write(to: manager.metadataPath(for: id))
    }

    private func makeOpenDatabase() throws -> BudgetDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("delete-budget-db-\(UUID().uuidString).sqlite")
        return try BudgetDatabase(path: url)
    }

    private func makeStubbedServerClient(status: Int = 200) async throws -> ActualServerClient {
        DeleteBudgetTransport.status = status
        DeleteBudgetTransport.requestedPaths = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeleteBudgetTransport.self]
        let client = ActualServerClient(session: URLSession(configuration: configuration))
        try await client.configure(serverURL: "https://budget.example.com")
        await client.setToken("test-token")
        return client
    }

    // MARK: - Remove from this device

    @Test func removesOnlyTheTargetedBudgetIncludingBackups() throws {
        let saved = UserDefaults.standard.string(forKey: "currentBudgetId")
        defer { UserDefaults.standard.set(saved, forKey: "currentBudgetId") }
        let (store, manager) = try makeIsolatedStore()
        try seedBudget(id: "budget-a", cloudFileId: "file-a", in: manager)
        try seedBudget(id: "budget-b", cloudFileId: "file-b", in: manager)

        store.removeLocalBudget(cloudFileId: "file-a")

        #expect(!manager.budgetExists("budget-a"))
        #expect(!FileManager.default.fileExists(atPath: manager.budgetDirectory(for: "budget-a").path))
        // The neighbor is untouched, backups included.
        #expect(manager.budgetExists("budget-b"))
        #expect(FileManager.default.fileExists(
            atPath: manager.backupPath(for: "budget-b", name: "2026-01-01_00-00-00.zip").path
        ))
    }

    @Test func removingTheOpenBudgetClosesItAndReturnsToEmptyState() throws {
        let saved = UserDefaults.standard.string(forKey: "currentBudgetId")
        defer { UserDefaults.standard.set(saved, forKey: "currentBudgetId") }
        let (store, manager) = try makeIsolatedStore()
        try seedBudget(id: "budget-a", cloudFileId: "file-a", in: manager)
        store.currentBudgetId = "budget-a"
        store.configureForTesting(
            database: try makeOpenDatabase(),
            syncClient: SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        )
        store.accounts = [
            Account(id: "a1", name: "Checking", type: .checking,
                    offBudget: false, closed: false, sortOrder: 0, balance: 100)
        ]

        store.removeLocalBudget(cloudFileId: "file-a")

        #expect(store.currentBudgetId == nil)
        #expect(store.databaseForLogger == nil)
        #expect(store.accounts.isEmpty)
        #expect(!manager.budgetExists("budget-a"))
    }

    @Test func removingAnotherBudgetLeavesTheOpenOneAlone() throws {
        let saved = UserDefaults.standard.string(forKey: "currentBudgetId")
        defer { UserDefaults.standard.set(saved, forKey: "currentBudgetId") }
        let (store, manager) = try makeIsolatedStore()
        try seedBudget(id: "budget-a", cloudFileId: "file-a", in: manager)
        try seedBudget(id: "budget-b", cloudFileId: "file-b", in: manager)
        store.currentBudgetId = "budget-a"
        store.configureForTesting(
            database: try makeOpenDatabase(),
            syncClient: SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        )

        store.removeLocalBudget(cloudFileId: "file-b")

        #expect(store.currentBudgetId == "budget-a")
        #expect(store.databaseForLogger != nil)
        #expect(manager.budgetExists("budget-a"))
        #expect(!manager.budgetExists("budget-b"))
    }

    /// The derived encryption key must not outlive the files it unlocks.
    @Test func removalDeletesTheBudgetsEncryptionKey() throws {
        let saved = UserDefaults.standard.string(forKey: "currentBudgetId")
        defer { UserDefaults.standard.set(saved, forKey: "currentBudgetId") }
        let (store, manager) = try makeIsolatedStore()
        let fileId = "cloud-file-\(UUID().uuidString)"
        try seedBudget(id: "budget-enc", cloudFileId: fileId, encryptKeyId: "key-1", in: manager)
        try EncryptionKeyManager.store(
            LoadedKey(keyId: "key-1", key: SymmetricKey(size: .bits256)),
            fileId: fileId
        )
        defer { try? EncryptionKeyManager.remove(fileId: fileId) }

        store.removeLocalBudget(cloudFileId: fileId)

        #expect(EncryptionKeyManager.load(fileId: fileId) == nil)
    }

    // MARK: - Delete from server

    @Test func serverDeleteRemovesTheFileTheLocalCopyAndTheListRow() async throws {
        let saved = UserDefaults.standard.string(forKey: "currentBudgetId")
        defer { UserDefaults.standard.set(saved, forKey: "currentBudgetId") }
        let (store, manager) = try makeIsolatedStore()
        try seedBudget(id: "budget-a", cloudFileId: "file-a", in: manager)
        store.setServerClientForTesting(try await makeStubbedServerClient())
        let remote = BudgetStore.RemoteBudget(
            id: "file-a", name: "Test Budget", groupId: nil, isEncrypted: false
        )
        store.remoteBudgets = [
            remote,
            BudgetStore.RemoteBudget(id: "file-b", name: "Other", groupId: nil, isEncrypted: false),
        ]

        let failure = await store.deleteServerBudget(remote)

        #expect(failure == nil)
        #expect(DeleteBudgetTransport.requestedPaths == ["/sync/delete-user-file"])
        #expect(!manager.budgetExists("budget-a"))
        #expect(store.remoteBudgets.map(\.id) == ["file-b"])
    }

    /// A file already deleted from another client answers file-not-found; the
    /// local half still runs so the stale row heals instead of erroring.
    @Test func serverDeleteTreatsFileNotFoundAsSuccess() async throws {
        let saved = UserDefaults.standard.string(forKey: "currentBudgetId")
        defer { UserDefaults.standard.set(saved, forKey: "currentBudgetId") }
        let (store, manager) = try makeIsolatedStore()
        try seedBudget(id: "budget-a", cloudFileId: "file-a", in: manager)
        store.setServerClientForTesting(try await makeStubbedServerClient(status: 400))
        let remote = BudgetStore.RemoteBudget(
            id: "file-a", name: "Test Budget", groupId: nil, isEncrypted: false
        )
        store.remoteBudgets = [remote]

        let failure = await store.deleteServerBudget(remote)

        #expect(failure == nil)
        #expect(!manager.budgetExists("budget-a"))
        #expect(store.remoteBudgets.isEmpty)
    }

    /// Any other server failure aborts the whole delete: the local copy and
    /// backups must survive until the server file is actually gone.
    @Test func serverFailureKeepsTheLocalCopyAndBackups() async throws {
        let saved = UserDefaults.standard.string(forKey: "currentBudgetId")
        defer { UserDefaults.standard.set(saved, forKey: "currentBudgetId") }
        let (store, manager) = try makeIsolatedStore()
        try seedBudget(id: "budget-a", cloudFileId: "file-a", in: manager)
        store.setServerClientForTesting(try await makeStubbedServerClient(status: 500))
        let remote = BudgetStore.RemoteBudget(
            id: "file-a", name: "Test Budget", groupId: nil, isEncrypted: false
        )
        store.remoteBudgets = [remote]

        let failure = await store.deleteServerBudget(remote)

        #expect(failure != nil)
        #expect(manager.budgetExists("budget-a"))
        #expect(FileManager.default.fileExists(
            atPath: manager.backupPath(for: "budget-a", name: "2026-01-01_00-00-00.zip").path
        ))
        #expect(store.remoteBudgets.map(\.id) == ["file-a"])
    }
}
