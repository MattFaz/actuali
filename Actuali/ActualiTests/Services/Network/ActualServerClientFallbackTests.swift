import Foundation
import Synchronization
import Testing
@testable import Actuali

/// A primary and a fallback host whose reachability a test flips mid-run.
/// Starts with the primary down, since that is what every failover needs.
private final class FallbackServers: Sendable {
    private struct State {
        var requestedURLs: [URL] = []
        var failures = ["primary.example.com": URLError(.cannotConnectToHost)]
        var statuses: [String: Int] = [:]
    }

    private let state = Mutex(State())

    var requestedURLs: [URL] {
        state.withLock { $0.requestedURLs }
    }

    var failures: [String: URLError] {
        get { state.withLock { $0.failures } }
        set { state.withLock { $0.failures = newValue } }
    }

    var statuses: [String: Int] {
        get { state.withLock { $0.statuses } }
        set { state.withLock { $0.statuses = newValue } }
    }

    func session() -> URLSession {
        StubTransport.session { request in
            let host = request.url?.host ?? ""
            let (failure, status) = self.state.withLock { state in
                state.requestedURLs.append(request.url!)
                return (state.failures[host], state.statuses[host] ?? 200)
            }
            if let failure {
                throw failure
            }
            return StubTransport.Response(
                status: status,
                contentType: "application/json",
                body: Data(#"{"status":"ok","data":{"token":"fallback-token"}}"#.utf8)
            )
        }
    }
}

struct ActualServerClientFallbackTests {
    private func makeClient(fallbackServerURL: String = "https://fallback.example.com") async throws
        -> (ActualServerClient, FallbackServers) {
        let servers = FallbackServers()
        let client = ActualServerClient(session: servers.session())
        try await client.configure(
            serverURL: "https://primary.example.com",
            fallbackServerURL: fallbackServerURL
        )
        return (client, servers)
    }

    @Test func retriesAtFallbackWhenPrimaryCannotBeReached() async throws {
        let (client, servers) = try await makeClient()

        let token = try await client.login(password: "password")

        #expect(token == "fallback-token")
        #expect(servers.requestedURLs.map(\.host) == [
            "primary.example.com", "fallback.example.com",
        ])
    }

    @Test func doesNotRetryWithoutAFallbackAddress() async throws {
        let (client, servers) = try await makeClient(fallbackServerURL: "")

        await #expect(throws: ActualServerError.self) {
            _ = try await client.login(password: "password")
        }
        #expect(servers.requestedURLs.map(\.host) == ["primary.example.com"])
    }

    @Test func preservesFallbackAddressPathPrefix() async throws {
        let (client, servers) = try await makeClient(
            fallbackServerURL: "https://fallback.example.com/actual"
        )

        _ = try await client.login(password: "password")

        #expect(servers.requestedURLs.last?.path == "/actual/account/login")
    }

    @Test func sticksWithFallbackOnceItSucceeds() async throws {
        let (client, servers) = try await makeClient()
        _ = try await client.login(password: "password")
        // Even with the primary healthy again, the session keeps using the
        // address that answered instead of paying a probe on every request.
        servers.failures = [:]

        _ = try await client.login(password: "password")

        #expect(servers.requestedURLs.map(\.host) == [
            "primary.example.com", "fallback.example.com", "fallback.example.com",
        ])
    }

    @Test func returnsToPrimaryWhenFallbackFailsLater() async throws {
        let (client, servers) = try await makeClient()
        _ = try await client.login(password: "password")
        servers.failures = ["fallback.example.com": URLError(.cannotConnectToHost)]

        _ = try await client.login(password: "password")
        _ = try await client.login(password: "password")

        #expect(servers.requestedURLs.map(\.host) == [
            "primary.example.com", "fallback.example.com",
            "fallback.example.com", "primary.example.com",
            "primary.example.com",
        ])
    }

    @Test func foregroundProbeSwapsBackWhenPrimaryRecovers() async throws {
        let (client, servers) = try await makeClient()
        _ = try await client.login(password: "password")
        servers.failures = [:]

        await client.retryPrimaryIfRecovered()
        _ = try await client.login(password: "password")

        #expect(servers.requestedURLs.map(\.host) == [
            "primary.example.com", "fallback.example.com",
            "primary.example.com", "primary.example.com",
        ])
        #expect(servers.requestedURLs[2].path == "/info")
    }

    @Test func foregroundProbeKeepsFallbackWhilePrimaryIsDown() async throws {
        let (client, servers) = try await makeClient()
        _ = try await client.login(password: "password")

        await client.retryPrimaryIfRecovered()
        _ = try await client.login(password: "password")

        #expect(servers.requestedURLs.map(\.host) == [
            "primary.example.com", "fallback.example.com",
            "primary.example.com", "fallback.example.com",
        ])
    }

    @Test func surfacesPrimaryErrorWhenBothAddressesFail() async throws {
        let (client, servers) = try await makeClient()
        servers.failures = [
            "primary.example.com": URLError(.secureConnectionFailed),
            "fallback.example.com": URLError(.cannotFindHost),
        ]

        do {
            _ = try await client.login(password: "password")
            Issue.record("Expected the request to fail")
        } catch let error as ActualServerError {
            guard case .networkError(let underlying) = error,
                  let urlError = underlying as? URLError else {
                Issue.record("Expected a networkError, got \(error)")
                return
            }
            // The primary's error is the actionable one; the fallback's
            // failure is only logged.
            #expect(urlError.code == .secureConnectionFailed)
        }
    }

    @Test func foregroundProbeAcceptsPrimariesWithoutAnInfoRoute() async throws {
        let (client, servers) = try await makeClient()
        _ = try await client.login(password: "password")
        servers.failures = [:]
        servers.statuses = ["primary.example.com": 404]

        await client.retryPrimaryIfRecovered()
        servers.statuses = [:]
        _ = try await client.login(password: "password")

        #expect(servers.requestedURLs.map(\.host) == [
            "primary.example.com", "fallback.example.com",
            "primary.example.com", "primary.example.com",
        ])
    }

    @Test func foregroundProbeStaysOnFallbackWhenPrimaryAnswers5xx() async throws {
        let (client, servers) = try await makeClient()
        _ = try await client.login(password: "password")
        servers.failures = [:]
        servers.statuses = ["primary.example.com": 502]

        await client.retryPrimaryIfRecovered()
        _ = try await client.login(password: "password")

        #expect(servers.requestedURLs.map(\.host) == [
            "primary.example.com", "fallback.example.com",
            "primary.example.com", "fallback.example.com",
        ])
    }

    @Test func foregroundProbeIsANoOpBeforeAnyFailover() async throws {
        let (client, servers) = try await makeClient()
        servers.failures = [:]

        await client.retryPrimaryIfRecovered()

        #expect(servers.requestedURLs.isEmpty)
    }

    @Test func diagnosticHistoryTracksFallbackAndPrimaryRecovery() async throws {
        let servers = FallbackServers()
        let log = DiagnosticLog()
        let client = ActualServerClient(
            session: servers.session(),
            diagnosticLog: log
        )
        try await client.configure(
            serverURL: "https://primary.example.com",
            fallbackServerURL: "https://fallback.example.com"
        )

        _ = try await client.login(password: "password")

        var snapshot = await log.snapshot()
        let firstReport = snapshot.entries.map(\.message).joined(separator: "\n")
        #expect(firstReport.contains(
            "NETWORK method=POST path=/account/login status=none error=cannot-connect"
        ))
        #expect(firstReport.contains(
            "NETWORK method=POST path=/account/login status=200 error=none"
        ))
        #expect(snapshot.serverRoute == "fallback")
        #expect(firstReport.contains("ROUTE fallback"))

        servers.failures = [:]
        await client.retryPrimaryIfRecovered()

        snapshot = await log.snapshot()
        let report = snapshot.entries.map(\.message).joined(separator: "\n")
        #expect(report.contains(
            "NETWORK method=GET path=/info status=200 error=none"
        ))
        #expect(report.contains("ROUTE primary"))
        #expect(snapshot.serverRoute == "primary")
    }

    @Test func diagnosticPathOmitsConfiguredServerPathPrefixes() async throws {
        let servers = FallbackServers()
        let log = DiagnosticLog()
        let client = ActualServerClient(
            session: servers.session(),
            diagnosticLog: log
        )

        try await client.configure(
            serverURL: "https://primary.example.com/private-route",
            fallbackServerURL: "https://fallback.example.com/fallback-route"
        )
        _ = try await client.login(password: "password")

        let report = (await log.snapshot()).entries
            .map(\.message)
            .joined(separator: "\n")
        #expect(report.contains(
            "NETWORK method=POST path=/account/login status=200 error=none"
        ))
        #expect(!report.contains("/private-route"))
        #expect(!report.contains("/fallback-route"))
    }

    @Test func diagnosticHistoryTracksFallbackFailure() async throws {
        let servers = FallbackServers()
        servers.failures = [
            "primary.example.com": URLError(.secureConnectionFailed),
            "fallback.example.com": URLError(.cannotFindHost),
        ]
        let log = DiagnosticLog()
        let client = ActualServerClient(
            session: servers.session(),
            diagnosticLog: log
        )
        try await client.configure(
            serverURL: "https://primary.example.com",
            fallbackServerURL: "https://fallback.example.com"
        )

        await #expect(throws: ActualServerError.self) {
            _ = try await client.login(password: "password")
        }

        let snapshot = await log.snapshot()
        let report = snapshot.entries.map(\.message).joined(separator: "\n")
        #expect(
            report.contains(
                "NETWORK method=POST path=/account/login status=none error=tls("
                    + String(URLError.Code.secureConnectionFailed.rawValue)
                    + ")"
            )
        )
        #expect(report.contains(
            "NETWORK method=POST path=/account/login status=none error=host-not-found"
        ))
    }

    @Test func offlineDeviceDoesNotAttemptFallback() async throws {
        let (client, servers) = try await makeClient()
        servers.failures = ["primary.example.com": URLError(.notConnectedToInternet)]

        await #expect(throws: ActualServerError.self) {
            _ = try await client.login(password: "password")
        }

        #expect(servers.requestedURLs.map(\.host) == ["primary.example.com"])
    }

    @Test func malformedFallbackHasSpecificError() async {
        let client = ActualServerClient()

        do {
            try await client.configure(
                serverURL: "https://primary.example.com",
                fallbackServerURL: "https://"
            )
            Issue.record("Expected malformed fallback URL to be rejected")
        } catch {
            #expect(error.localizedDescription == "Invalid fallback server URL")
        }
    }

    @Test func invalidFallbackDoesNotPublishDiagnosticConfiguration() async {
        let log = DiagnosticLog()
        let client = ActualServerClient(diagnosticLog: log)

        do {
            try await client.configure(
                serverURL: "https://primary.example.com",
                fallbackServerURL: "https://"
            )
            Issue.record("Expected invalid fallback URL")
        } catch ActualServerError.invalidFallbackURL {
            // Expected.
        } catch {
            Issue.record("Expected invalidFallbackURL, got \(String(describing: error))")
        }

        let snapshot = await log.snapshot()
        #expect(snapshot == .empty)
    }

    @Test func badFallbackStillConfiguresPrimary() async throws {
        // configureSavedSession swallows configure errors with try?; a bad
        // fallback must degrade to "no fallback", not an unconfigured client.
        let servers = FallbackServers()
        let client = ActualServerClient(session: servers.session())
        servers.failures = [:]
        await #expect(throws: ActualServerError.self) {
            try await client.configure(
                serverURL: "https://primary.example.com",
                fallbackServerURL: "no-scheme.example.com"
            )
        }

        let token = try await client.login(password: "password")

        #expect(token == "fallback-token")
        #expect(servers.requestedURLs.map(\.host) == ["primary.example.com"])
    }
}
