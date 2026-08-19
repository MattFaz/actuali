import CryptoKit
import Foundation
import GRDB
import Testing
@testable import Actuali

/// Coverage for logout()'s local-data wipe: disconnecting must close the open
/// database and sync client before deleting budget files (the same
/// vnode-unlink hazard downloadBudget guards against), clear every piece of
/// published budget state so nothing resurfaces on the next foreground
/// refresh, and remove encrypted budgets' keys from the Keychain.
@MainActor
struct BudgetStoreLogoutTests {

    /// Store + file manager rooted in a unique temp directory. logout wipes
    /// *all* local budgets, and suites run in parallel against the shared
    /// Budgets directory, so isolation is mandatory for these tests.
    private func makeIsolatedStore() throws -> (BudgetStore, BudgetFileManager) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("logout-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = BudgetFileManager(rootDirectoryForTesting: root)
        let store = BudgetStore.previewInstance()
        store.setFileManagerForTesting(manager)
        return (store, manager)
    }

    /// On-disk budget with the metadata.json that listLocalBudgets() keys on.
    private func seedBudget(
        id: String,
        cloudFileId: String? = nil,
        encryptKeyId: String? = nil,
        in manager: BudgetFileManager
    ) throws {
        let dir = manager.budgetDirectory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("stub".utf8).write(to: manager.databasePath(for: id))
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
            .appendingPathComponent("logout-db-\(UUID().uuidString).sqlite")
        return try BudgetDatabase(path: url)
    }

    private func makeSyncClient() -> SyncClient {
        SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
    }

    @Test func deletesEveryLocalBudgetFromDisk() throws {
        let saved = UserDefaults.standard.string(forKey: "currentBudgetId")
        defer { UserDefaults.standard.set(saved, forKey: "currentBudgetId") }
        let (store, manager) = try makeIsolatedStore()
        try seedBudget(id: "budget-a", in: manager)
        try seedBudget(id: "budget-b", in: manager)
        #expect(manager.listLocalBudgets().count == 2)

        store.logout()

        #expect(manager.listLocalBudgets().isEmpty)
        #expect(!manager.budgetExists("budget-a"))
        #expect(!manager.budgetExists("budget-b"))
    }

    /// The open GRDB connection must be closed before the files go — an
    /// unlinked-but-open database stays readable through its fd, so a later
    /// foreground refresh would republish the "deleted" budget's data.
    @Test func tearsDownDatabaseAndSyncClient() async throws {
        let saved = UserDefaults.standard.string(forKey: "currentBudgetId")
        defer { UserDefaults.standard.set(saved, forKey: "currentBudgetId") }
        let (store, manager) = try makeIsolatedStore()
        try seedBudget(id: "budget-a", in: manager)
        store.configureForTesting(database: try makeOpenDatabase(), syncClient: makeSyncClient())

        store.logout()

        #expect(store.databaseForLogger == nil)
        // The sync client is gone too: with no client and no saved budget,
        // a background sync reports "nothing to sync".
        #expect(await store.syncInBackground() == false)
    }

    @Test func clearsAllPublishedBudgetState() throws {
        let saved = UserDefaults.standard.string(forKey: "currentBudgetId")
        defer { UserDefaults.standard.set(saved, forKey: "currentBudgetId") }
        let (store, _) = try makeIsolatedStore()
        store.currentBudgetId = "budget-a"
        store.accounts = [
            Account(id: "a1", name: "Checking", type: .checking,
                    offBudget: false, closed: false, sortOrder: 0, balance: 100)
        ]
        store.transactions = [
            Transaction(id: "t1", accountId: "a1", date: 20260810, amount: -500,
                        payeeId: nil, payeeName: nil, categoryId: nil, categoryName: nil,
                        notes: nil, cleared: false, reconciled: false, transferId: nil,
                        isParent: false, parentId: nil, tombstone: false, sortOrder: nil,
                        importedPayee: nil)
        ]
        store.uncategorizedCount = 3
        store.payees = [Payee(id: "p1", name: "Grocer")]
        store.lastSyncTime = Date()

        store.logout()

        #expect(store.currentBudgetId == nil)
        #expect(store.accounts.isEmpty)
        #expect(store.transactions.isEmpty)
        #expect(store.uncategorizedCount == 0)
        #expect(store.payees.isEmpty)
        #expect(store.lastSyncTime == nil)
    }

    /// "Leave nothing behind" includes the Keychain: an encrypted budget's
    /// derived key must not outlive the budget files it unlocks.
    @Test func removesEncryptionKeysForDeletedBudgets() throws {
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

        store.logout()

        #expect(EncryptionKeyManager.load(fileId: fileId) == nil)
    }

    /// The demo entry point (loadDemoData) clears the session so sync can't
    /// fire against a real server, but it must not destroy locally-synced
    /// budgets — only an explicit Disconnect wipes data.
    @Test func preservesLocalDataWhenAskedTo() throws {
        let saved = UserDefaults.standard.string(forKey: "currentBudgetId")
        defer { UserDefaults.standard.set(saved, forKey: "currentBudgetId") }
        let (store, manager) = try makeIsolatedStore()
        try seedBudget(id: "budget-a", in: manager)
        store.configureForTesting(database: try makeOpenDatabase(), syncClient: makeSyncClient())

        store.logout(clearLocalData: false)

        // The session and open connections still reset...
        #expect(store.isConnected == false)
        #expect(store.databaseForLogger == nil)
        // ...but the on-disk budget survives.
        #expect(manager.budgetExists("budget-a"))
        #expect(manager.listLocalBudgets().count == 1)
    }
}
