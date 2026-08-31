import Foundation
import Testing

@testable import Actuali

/// In-app budget creation (GH #387): name validation mirrors upstream's
/// validateBudgetName, and the create flow builds the file from the bundled
/// template, registers it via /sync/upload-user-file, and opens it.
private final class CreateBudgetTransport: URLProtocol {
    nonisolated(unsafe) static var uploadRequests: [URLRequest] = []
    nonisolated(unsafe) static var uploadStatus = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        var status = 200
        var body = #"{"status":"ok"}"#

        switch path {
        case let p where p.hasSuffix("/sync/upload-user-file"):
            Self.uploadRequests.append(request)
            status = Self.uploadStatus
            body = #"{"status":"ok","groupId":"group-fresh-1"}"#
        case let p where p.hasSuffix("/sync/list-user-files"):
            body = #"{"status":"ok","data":[]}"#
        default:
            break
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

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
        let (store, _, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.remoteBudgets = [
            .init(id: "f1", name: "Existing", groupId: "g1", isEncrypted: false)
        ]

        await store.createBudget(named: "  Existing  ")

        #expect(store.error?.contains("already exists") == true)
        #expect(store.currentBudgetId == nil)
        #expect(CreateBudgetTransport.uploadRequests.isEmpty)
    }

    // MARK: - End-to-end create

    private func makeStore() async throws -> (BudgetStore, BudgetFileManager, URL) {
        CreateBudgetTransport.uploadRequests = []
        CreateBudgetTransport.uploadStatus = 200

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manager = BudgetFileManager(rootDirectoryForTesting: root)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CreateBudgetTransport.self]
        let client = ActualServerClient(session: URLSession(configuration: configuration))
        try await client.configure(serverURL: "https://server.example.com")
        await client.setToken("token-1")

        let store = BudgetStore.previewInstance()
        store.setFileManagerForTesting(manager)
        store.setServerClientForTesting(client)
        return (store, manager, root)
    }

    /// The whole flow against the real bundled template: local files created,
    /// the upload registered with upstream's headers, the returned groupId
    /// persisted, and the budget opened with upstream's default categories.
    @Test func createBudgetRegistersAndOpens() async throws {
        let (store, manager, root) = try await makeStore()
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
        let upload = try #require(CreateBudgetTransport.uploadRequests.first)
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
        let (store, manager, root) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        CreateBudgetTransport.uploadStatus = 500

        await store.createBudget(named: "Doomed")

        #expect(store.error != nil)
        #expect(store.currentBudgetId == nil)
        #expect(manager.listLocalBudgets().isEmpty)
    }
}
