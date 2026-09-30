import Foundation
import GRDB
import Synchronization
import Testing
@testable import Actuali

/// What the stubbed server saw: every upload request, and the file it
/// committed (so /sync/list-user-files can report it back).
private final class UploadLog: Sendable {
    let requests = Mutex<[URLRequest]>([])
    let committed = Mutex<(fileId: String, name: String)?>(nil)
}

/// In-app budget creation (GH #387): name validation mirrors upstream's
/// validateBudgetName, and the create flow builds the file from the bundled
/// template, registers it via /sync/upload-user-file, and opens it.
@MainActor
@Suite(.serialized)
struct BudgetStoreCreateBudgetTests {
    // MARK: - Name validation (upstream validateBudgetName)

    @Test func nameValidationMirrorsUpstream() {
        #expect(BudgetStore.budgetNameError("", existingNames: []) == "Budget name cannot be blank")
        #expect(BudgetStore.budgetNameError(String(repeating: "x", count: 101), existingNames: [])
            == "Budget name is too long (max length 100)")
        #expect(BudgetStore.budgetNameError("Mine", existingNames: ["Mine"]) != nil)
        #expect(BudgetStore.budgetNameError("Mine", existingNames: ["Other"]) == nil)
        #expect(BudgetStore.budgetNameError(String(repeating: "x", count: 100), existingNames: []) == nil)
    }

    @Test func createRejectsDuplicateOfServerFile() async throws {
        let (store, _, root, log) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.remoteBudgets = [
            .init(id: "f1", name: "Existing", groupId: "g1", isEncrypted: false),
        ]

        await store.createBudget(named: "  Existing  ")

        #expect(store.error?.contains("already exists") == true)
        #expect(store.currentBudgetId == nil)
        #expect(log.requests.withLock { $0.isEmpty })
    }

    // MARK: - End-to-end create

    /// Store over a stubbed server that registers uploads and lists them back.
    /// `afterUpload` runs once the upload has been committed, before the
    /// response is (or isn't) delivered.
    private func makeStore(
        uploadStatus: Int = 200,
        dropUploadResponse: Bool = false,
        failFileList: Bool = false,
        afterUpload: (@Sendable (BudgetFileManager) -> Void)? = nil
    ) async throws -> (BudgetStore, BudgetFileManager, URL, UploadLog) {
        let (store, manager, root) = makeFileBackedStore()
        let log = UploadLog()
        let session = StubTransport.session { request in
            let path = request.url?.path ?? ""
            var status = 200
            var body = #"{"status":"ok"}"#

            switch path {
            case let p where p.hasSuffix("/sync/upload-user-file"):
                log.requests.withLock { $0.append(request) }
                status = uploadStatus
                body = #"{"status":"ok","groupId":"group-fresh-1"}"#
                if status == 200 {
                    if let fileId = request.value(forHTTPHeaderField: "X-ACTUAL-FILE-ID"),
                       let name = request.value(forHTTPHeaderField: "X-ACTUAL-NAME")?.removingPercentEncoding {
                        log.committed.withLock { $0 = (fileId, name) }
                    }
                    afterUpload?(manager)
                    if dropUploadResponse {
                        throw URLError(.networkConnectionLost)
                    }
                }
            case let p where p.hasSuffix("/sync/list-user-files"):
                if failFileList {
                    throw URLError(.networkConnectionLost)
                }
                if let committed = log.committed.withLock({ $0 }) {
                    body = #"{"status":"ok","data":[{"fileId":"\#(committed.fileId)","groupId":"group-fresh-1","name":"\#(committed.name)","deleted":0}]}"#
                } else {
                    body = #"{"status":"ok","data":[]}"#
                }
            default:
                break
            }
            return .init(status: status, contentType: "application/json", body: Data(body.utf8))
        }

        let client = ActualServerClient(session: session)
        try await client.configure(serverURL: "https://server.example.com")
        await client.setToken("token-1")
        store.setServerClientForTesting(client)
        return (store, manager, root, log)
    }

    /// The whole flow against the real bundled template: local files created,
    /// the upload registered with upstream's headers, the returned groupId
    /// persisted, and the budget opened with upstream's default categories.
    @Test func createBudgetRegistersAndOpens() async throws {
        let (store, manager, root, log) = try await makeStore()
        defer {
            // Close the DB before deleting its directory — createBudget opens a
            // live GRDB connection, and unlinking db.sqlite underneath it trips
            // "vnode unlinked while in use".
            store.closeDatabaseForTesting()
            try? FileManager.default.removeItem(at: root)
        }

        await store.createBudget(named: "Fresh Start")

        #expect(store.error == nil)
        let budgetId = try #require(store.currentBudgetId)
        #expect(budgetId.hasPrefix("Fresh-Start-"))

        // Metadata carries the server registration, like a downloaded file's.
        let metadata = try #require(manager.listLocalBudgets().first { $0.id == budgetId })
        #expect(metadata.groupId == "group-fresh-1")
        let cloudFileId = try #require(metadata.cloudFileId)
        #expect(cloudFileId == cloudFileId.lowercased())
        #expect(metadata.lastUploaded != nil)

        // The upload used upstream's header protocol (cloud-storage.ts:339).
        let upload = try #require(log.requests.withLock { $0.first })
        #expect(upload.value(forHTTPHeaderField: "X-ACTUAL-FILE-ID") == cloudFileId)
        #expect(upload.value(forHTTPHeaderField: "X-ACTUAL-NAME") == "Fresh%20Start")
        #expect(upload.value(forHTTPHeaderField: "X-ACTUAL-FORMAT") == "2")
        #expect(upload.value(forHTTPHeaderField: "X-ACTUAL-GROUP-ID") == nil)

        // The template's upstream default categories are live in the store.
        #expect(store.categoryGroups.map(\.name).contains("Usual Expenses"))
        #expect(store.isSyncConfiguredForTesting)
    }

    /// A failed registration must not strand an unsyncable local-only file.
    @Test func failedUploadRollsBackLocalFiles() async throws {
        let (store, manager, root, _) = try await makeStore(uploadStatus: 500)
        defer { try? FileManager.default.removeItem(at: root) }

        await store.createBudget(named: "Doomed")

        #expect(store.error != nil)
        #expect(store.currentBudgetId == nil)
        #expect(manager.listLocalBudgets().isEmpty)
    }

    @Test func committedUploadSurvivesLostResponse() async throws {
        let (store, manager, root, log) = try await makeStore(dropUploadResponse: true)
        defer {
            store.closeDatabaseForTesting()
            try? FileManager.default.removeItem(at: root)
        }

        await store.createBudget(named: "Recovered")

        #expect(store.error == nil)
        let committedFileId = try #require(log.committed.withLock { $0?.fileId })
        let metadata = try #require(manager.listLocalBudgets().first)
        #expect(metadata.cloudFileId == committedFileId)
        #expect(metadata.groupId == "group-fresh-1")
        #expect(store.currentBudgetId == metadata.id)
    }

    @Test func unknownUploadOutcomeRemovesLocalCopy() async throws {
        let (store, manager, root, _) = try await makeStore(dropUploadResponse: true, failFileList: true)
        defer { try? FileManager.default.removeItem(at: root) }

        await store.createBudget(named: "Uncertain")

        #expect(store.error?.contains("Reopen Connection & Data") == true)
        #expect(manager.listLocalBudgets().isEmpty)
        #expect(store.currentBudgetId == nil)
    }

    @Test func localOpenErrorIsNotClearedByRemoteRefresh() async throws {
        let (store, _, root, _) = try await makeStore(afterUpload: { manager in
            guard let budgetId = manager.listLocalBudgets().first?.id else { return }
            try? Data("not sqlite".utf8).write(to: manager.databasePath(for: budgetId))
        })
        defer { try? FileManager.default.removeItem(at: root) }
        store.accounts = [
            .init(
                id: "old", name: "Old", type: .checking, offBudget: false,
                closed: false, sortOrder: 0, balance: 0
            ),
        ]

        await store.createBudget(named: "Broken Local Copy")

        #expect(store.error?.hasPrefix("Failed to load budget:") == true)
        #expect(store.accounts.isEmpty)
        #expect(!store.isSyncConfiguredForTesting)
    }

    @Test func syncSetupErrorKeepsPublishedBudgetVisible() async throws {
        let (store, _, root, _) = try await makeStore(afterUpload: { manager in
            guard let budgetId = manager.listLocalBudgets().first?.id,
                  let queue = try? DatabaseQueue(path: manager.databasePath(for: budgetId).path)
            else { return }
            try? queue.write { db in
                try db.execute(sql: """
                DROP TABLE messages_clock;
                CREATE TABLE messages_clock (bad TEXT);
                """)
            }
        })
        defer {
            store.closeDatabaseForTesting()
            try? FileManager.default.removeItem(at: root)
        }

        await store.createBudget(named: "Broken Sync State")

        #expect(store.error?.hasPrefix("Failed to load budget:") == true)
        #expect(store.categoryGroups.map(\.name).contains("Usual Expenses"))
        #expect(store.isSyncConfiguredForTesting)
    }
}
