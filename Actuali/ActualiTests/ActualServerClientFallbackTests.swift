import Foundation
import Testing
@testable import Actuali

private final class FallbackTransport: URLProtocol {
    nonisolated(unsafe) static var requestedURLs: [URL] = []
    nonisolated(unsafe) static var failures: [String: URLError] = [:]
    nonisolated(unsafe) static var statuses: [String: Int] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.requestedURLs.append(request.url!)

        if let failure = Self.failures[host] {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statuses[host] ?? 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data(#"{"status":"ok","data":{"token":"fallback-token"}}"#.utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct ActualServerClientFallbackTests {
    private func makeSession() -> URLSession {
        FallbackTransport.requestedURLs = []
        FallbackTransport.failures = ["primary.example.com": URLError(.cannotConnectToHost)]
        FallbackTransport.statuses = [:]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FallbackTransport.self]
        return URLSession(configuration: configuration)
    }

    private func makeClient(fallbackServerURL: String = "https://fallback.example.com") async throws
        -> ActualServerClient {
        let client = ActualServerClient(session: makeSession())
        try await client.configure(
            serverURL: "https://primary.example.com",
            fallbackServerURL: fallbackServerURL
        )
        return client
    }

    @Test func retriesAtFallbackWhenPrimaryCannotBeReached() async throws {
        let client = try await makeClient()

        let token = try await client.login(password: "password")

        #expect(token == "fallback-token")
        #expect(FallbackTransport.requestedURLs.map(\.host) == [
            "primary.example.com", "fallback.example.com"
        ])
    }

    @Test func doesNotRetryWithoutAFallbackAddress() async throws {
        let client = try await makeClient(fallbackServerURL: "")

        await #expect(throws: ActualServerError.self) {
            _ = try await client.login(password: "password")
        }
        #expect(FallbackTransport.requestedURLs.map(\.host) == ["primary.example.com"])
    }

    @Test func preservesFallbackAddressPathPrefix() async throws {
        let client = try await makeClient(
            fallbackServerURL: "https://fallback.example.com/actual"
        )

        _ = try await client.login(password: "password")

        #expect(FallbackTransport.requestedURLs.last?.path == "/actual/account/login")
    }

    @Test func sticksWithFallbackOnceItSucceeds() async throws {
        let client = try await makeClient()
        _ = try await client.login(password: "password")
        // Even with the primary healthy again, the session keeps using the
        // address that answered instead of paying a probe on every request.
        FallbackTransport.failures = [:]

        _ = try await client.login(password: "password")

        #expect(FallbackTransport.requestedURLs.map(\.host) == [
            "primary.example.com", "fallback.example.com", "fallback.example.com"
        ])
    }

    @Test func returnsToPrimaryWhenFallbackFailsLater() async throws {
        let client = try await makeClient()
        _ = try await client.login(password: "password")
        FallbackTransport.failures = ["fallback.example.com": URLError(.cannotConnectToHost)]

        _ = try await client.login(password: "password")
        _ = try await client.login(password: "password")

        #expect(FallbackTransport.requestedURLs.map(\.host) == [
            "primary.example.com", "fallback.example.com",
            "fallback.example.com", "primary.example.com",
            "primary.example.com"
        ])
    }

    @Test func foregroundProbeSwapsBackWhenPrimaryRecovers() async throws {
        let client = try await makeClient()
        _ = try await client.login(password: "password")
        FallbackTransport.failures = [:]

        await client.retryPrimaryIfRecovered()
        _ = try await client.login(password: "password")

        #expect(FallbackTransport.requestedURLs.map(\.host) == [
            "primary.example.com", "fallback.example.com",
            "primary.example.com", "primary.example.com"
        ])
        #expect(FallbackTransport.requestedURLs[2].path == "/info")
    }

    @Test func foregroundProbeKeepsFallbackWhilePrimaryIsDown() async throws {
        let client = try await makeClient()
        _ = try await client.login(password: "password")

        await client.retryPrimaryIfRecovered()
        _ = try await client.login(password: "password")

        #expect(FallbackTransport.requestedURLs.map(\.host) == [
            "primary.example.com", "fallback.example.com",
            "primary.example.com", "fallback.example.com"
        ])
    }

    @Test func surfacesPrimaryErrorWhenBothAddressesFail() async throws {
        let client = try await makeClient()
        FallbackTransport.failures = [
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
        let client = try await makeClient()
        _ = try await client.login(password: "password")
        FallbackTransport.failures = [:]
        FallbackTransport.statuses = ["primary.example.com": 404]

        await client.retryPrimaryIfRecovered()
        FallbackTransport.statuses = [:]
        _ = try await client.login(password: "password")

        #expect(FallbackTransport.requestedURLs.map(\.host) == [
            "primary.example.com", "fallback.example.com",
            "primary.example.com", "primary.example.com"
        ])
    }

    @Test func foregroundProbeStaysOnFallbackWhenPrimaryAnswers5xx() async throws {
        let client = try await makeClient()
        _ = try await client.login(password: "password")
        FallbackTransport.failures = [:]
        FallbackTransport.statuses = ["primary.example.com": 502]

        await client.retryPrimaryIfRecovered()
        _ = try await client.login(password: "password")

        #expect(FallbackTransport.requestedURLs.map(\.host) == [
            "primary.example.com", "fallback.example.com",
            "primary.example.com", "fallback.example.com"
        ])
    }

    @Test func foregroundProbeIsANoOpBeforeAnyFailover() async throws {
        let client = try await makeClient()
        FallbackTransport.failures = [:]

        await client.retryPrimaryIfRecovered()

        #expect(FallbackTransport.requestedURLs.isEmpty)
    }

    @Test func offlineDeviceDoesNotAttemptFallback() async throws {
        let client = try await makeClient()
        FallbackTransport.failures = ["primary.example.com": URLError(.notConnectedToInternet)]

        await #expect(throws: ActualServerError.self) {
            _ = try await client.login(password: "password")
        }

        #expect(FallbackTransport.requestedURLs.map(\.host) == ["primary.example.com"])
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

    @Test func badFallbackStillConfiguresPrimary() async throws {
        // configureSavedSession swallows configure errors with try?; a bad
        // fallback must degrade to "no fallback", not an unconfigured client.
        let client = ActualServerClient(session: makeSession())
        FallbackTransport.failures = [:]
        await #expect(throws: ActualServerError.self) {
            try await client.configure(
                serverURL: "https://primary.example.com",
                fallbackServerURL: "no-scheme.example.com"
            )
        }

        let token = try await client.login(password: "password")

        #expect(token == "fallback-token")
        #expect(FallbackTransport.requestedURLs.map(\.host) == ["primary.example.com"])
    }
}
