import Foundation
import Synchronization
import Testing
@testable import Actuali

/// The connect screen's state: when Connect is available, how the server's
/// budget list is fetched, and when the "select a budget" prompt appears.
@Suite(.serialized)
@MainActor
struct BudgetStoreConnectTests {
    private static let files = ListFilesResponse(
        status: "ok",
        data: [.init(fileId: "cloud-file-1", groupId: "group-1", name: "Test Budget", deleted: 0, encryptKeyId: nil)]
    )

    private final class RequestCounter: Sendable {
        private let count = Mutex(0)

        var value: Int {
            count.withLock { $0 }
        }

        func increment() {
            count.withLock { $0 += 1 }
        }
    }

    /// Store with a session on a stubbed server that signs any password in
    /// and lists one budget. `listRequests` counts how often the list was
    /// asked for.
    private func makeStore(listRequests: RequestCounter = RequestCounter()) async throws -> BudgetStore {
        let login = try JSONEncoder().encode(LoginResponse(status: "ok", data: .init(token: "test-token"), reason: nil))
        let files = try JSONEncoder().encode(Self.files)
        let session = StubTransport.session { request in
            let path = request.url?.path ?? ""
            if path.contains("account/login") {
                return StubTransport.Response(contentType: "application/json", body: login)
            }
            if path.contains("list-user-files") {
                listRequests.increment()
                return StubTransport.Response(contentType: "application/json", body: files)
            }
            throw URLError(.cannotConnectToHost)
        }
        let serverClient = ActualServerClient(session: session)
        try await serverClient.configure(serverURL: "https://budget.example.com")
        await serverClient.setToken("test-token")

        let store = BudgetStore.previewInstance()
        store.setServerClientForTesting(serverClient)
        return store
    }

    /// `serverURL` persists to UserDefaults and a sign-in writes the token to
    /// the Keychain; put both back so the host app is left as it was found.
    private func restoringSession(_ body: () async throws -> Void) async rethrows {
        let savedURL = UserDefaults.standard.string(forKey: "serverURL")
        let savedToken = Keychain.get(for: "authToken")
        defer {
            UserDefaults.standard.set(savedURL, forKey: "serverURL")
            if let savedToken {
                try? Keychain.set(savedToken, for: "authToken")
            } else {
                try? Keychain.remove(for: "authToken")
            }
        }
        try await body()
    }

    /// Connect with an empty password on a password server looked like a dead
    /// button: it probed the server and then did nothing.
    @Test func connectIsUnavailableWithoutAPasswordOnAPasswordServer() async throws {
        try await restoringSession {
            let store = BudgetStore.previewInstance()
            #expect(!store.canConnect(password: "hunter2"), "no server URL yet")

            store.serverURL = "https://budget.example.com"
            // Not probed yet: Connect is what finds out how the server signs in.
            #expect(store.canConnect(password: ""))

            store.availableLoginMethods = [LoginMethod(method: "password", displayName: "Password", active: 1)]
            #expect(!store.canConnect(password: ""))
            #expect(store.canConnect(password: "hunter2"))

            // OpenID is the active method: the password isn't what signs in.
            store.availableLoginMethods = [
                LoginMethod(method: "openid", displayName: "OpenID", active: 1),
                LoginMethod(method: "password", displayName: "Password", active: 0),
            ]
            #expect(store.canConnect(password: ""))
        }
    }

    /// Signing in and the budget section appearing both fetch the list at
    /// once; two requests meant the first to finish cleared the other's
    /// spinner and error.
    @Test func overlappingBudgetListFetchesShareOneRequest() async throws {
        let listRequests = RequestCounter()
        let store = try await makeStore(listRequests: listRequests)

        async let first: Void = store.fetchRemoteBudgets()
        async let second: Void = store.fetchRemoteBudgets()
        _ = await (first, second)

        #expect(listRequests.value == 1)
        #expect(store.remoteBudgets.map(\.name) == ["Test Budget"])
        #expect(store.isLoading == false)

        // A later fetch is a new request, not a replay of the finished one.
        await store.fetchRemoteBudgets()
        #expect(listRequests.value == 2)
    }

    /// The prompt is a nudge for a fresh connection; it used to come back on
    /// every visit to the screen for as long as no budget was selected.
    @Test func budgetPromptIsOfferedOncePerSignIn() async throws {
        try await restoringSession {
            let store = try await makeStore()
            #expect(!store.consumeBudgetSelectionPrompt(), "nothing signed in yet")

            await store.login(password: "hunter2")

            #expect(store.error == nil)
            #expect(store.consumeBudgetSelectionPrompt())
            #expect(!store.consumeBudgetSelectionPrompt())
        }
    }

    /// A sign-in whose budget list came back empty has nothing to offer; the
    /// prompt must not then turn up on a later visit once budgets exist.
    @Test func budgetPromptIsDroppedWhenTheConnectionHadNoBudgets() async throws {
        let store = try await makeStore()
        store.budgetSelectionPromptPending = true

        #expect(!store.consumeBudgetSelectionPrompt(), "no budgets listed yet")

        await store.fetchRemoteBudgets()
        #expect(store.remoteBudgets.count == 1)
        #expect(!store.consumeBudgetSelectionPrompt())
    }

    /// A list request that failed used to read as "No budgets were found on
    /// your server", which sent people looking for budgets that were there.
    @Test func failedBudgetListFetchIsReportedAsAFailureNotAnEmptyServer() async throws {
        // One store throughout, so the second fetch has a failure to clear.
        let listRequests = RequestCounter()
        let files = try JSONEncoder().encode(Self.files)
        let serverClient = ActualServerClient(session: StubTransport.session { _ in
            listRequests.increment()
            guard listRequests.value > 1 else { throw URLError(.cannotConnectToHost) }
            return StubTransport.Response(contentType: "application/json", body: files)
        })
        try await serverClient.configure(serverURL: "https://budget.example.com")
        await serverClient.setToken("test-token")
        let store = BudgetStore.previewInstance()
        store.setServerClientForTesting(serverClient)

        await store.fetchRemoteBudgets()

        #expect(store.remoteBudgetsLoadFailed)
        #expect(store.remoteBudgets.isEmpty)

        await store.fetchRemoteBudgets()

        #expect(!store.remoteBudgetsLoadFailed)
        #expect(store.remoteBudgets.count == 1)
    }
}
