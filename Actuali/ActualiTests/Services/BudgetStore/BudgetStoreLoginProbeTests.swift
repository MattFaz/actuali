import Foundation
import Testing
@testable import Actuali

/// Either fails the request outright or answers with a canned HTTP status, so
/// the login-methods probe can be driven down both paths without a server.
private enum ProbeOutcome {
    case failure(URLError)
    case status(Int)
}

/// `checkLoginMethods` deliberately swallows probe failures and falls back to
/// password login, which is right for older servers that lack the endpoint but
/// wrong when the server can't be reached at all — the user tapped Connect and
/// got no feedback whatsoever.
@MainActor
struct BudgetStoreLoginProbeTests {
    private func makeStore(_ outcome: ProbeOutcome) async -> BudgetStore {
        let session = StubTransport.session { _ in
            switch outcome {
            case .failure(let error):
                throw error
            case .status(let code):
                return StubTransport.Response(
                    status: code, contentType: "application/json", body: Data("{}".utf8)
                )
            }
        }
        let client = ActualServerClient(session: session)
        try? await client.configure(serverURL: "https://budget.example.com")

        let store = BudgetStore.previewInstance()
        store.setServerClientForTesting(client)
        return store
    }

    @Test func unreachableServerTellsTheUserWhyInsteadOfFailingSilently() async {
        let store = await makeStore(.failure(URLError(.secureConnectionFailed)))

        await store.checkLoginMethods()

        #expect(store.error?.localizedCaseInsensitiveContains("certificate") == true)
    }

    /// Password login still has to be offered after a connection failure, so
    /// the user can fix the server and retry without restarting the app.
    @Test func passwordLoginRemainsAvailableAfterAConnectionFailure() async {
        let store = await makeStore(.failure(URLError(.cannotConnectToHost)))

        await store.checkLoginMethods()

        #expect(store.passwordLoginActive)
    }

    /// The silent fallback exists for servers predating the endpoint, or
    /// proxies stripping the route. A reachable server that simply can't
    /// answer the probe must not raise an alert.
    @Test func reachableServerWithAnUnusableProbeStillFallsBackQuietly() async {
        let store = await makeStore(.status(500))

        await store.checkLoginMethods()

        #expect(store.error == nil)
        #expect(store.passwordLoginActive)
    }

    // MARK: - Discovery before Connect (GH #671)

    /// An unconfigured store whose stub server offers OpenID only at
    /// `budget.example.com`, so a probe of any other host fails.
    private func makeOpenIDStore() -> BudgetStore {
        let session = StubTransport.session { request in
            guard request.url?.host == "budget.example.com" else {
                throw URLError(.cannotFindHost)
            }
            return StubTransport.Response(
                status: 200,
                contentType: "application/json",
                body: Data(#"{"status":"ok","methods":[{"method":"openid","displayName":"OpenID","active":1}]}"#.utf8)
            )
        }
        let store = BudgetStore.previewInstance()
        store.setServerClientForTesting(ActualServerClient(session: session))
        return store
    }

    /// OpenID sign-in has to be offered as soon as the server URL is typed,
    /// not only after a password attempt has gone through Connect.
    @Test func typedServerURLDiscoversOpenIDBeforeAnyPasswordAttempt() async {
        let store = makeOpenIDStore()
        store.serverURL = "budget.example.com"

        await store.discoverLoginMethods()

        #expect(store.supportsOpenIDLogin)
        #expect(!store.passwordLoginActive)
        #expect(store.serverURL == "budget.example.com", "discovery must not rewrite the field mid-typing")
    }

    /// Discovery runs while the user is still typing, so a half-typed or
    /// unreachable URL must not raise an alert — Connect reports that.
    @Test func discoveryAgainstAnUnreachableURLStaysQuietAndUnprobed() async {
        let store = makeOpenIDStore()
        store.serverURL = "budget.example"

        await store.discoverLoginMethods()

        #expect(store.error == nil)
        #expect(store.availableLoginMethods.isEmpty)
    }
}
