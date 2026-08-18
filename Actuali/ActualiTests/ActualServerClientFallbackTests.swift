import Foundation
import Testing
@testable import Actuali

private final class FallbackTransport: URLProtocol {
    nonisolated(unsafe) static var requestedURLs: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.requestedURLs.append(request.url!)

        if host == "primary.example.com" {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
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
    private func makeClient(fallbackServerURL: String = "https://fallback.example.com") async throws
        -> ActualServerClient {
        FallbackTransport.requestedURLs = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FallbackTransport.self]
        let client = ActualServerClient(session: URLSession(configuration: configuration))
        try await client.configure(
            serverURL: "https://primary.example.com",
            fallbackServerURL: fallbackServerURL
        )
        return client
    }

    @Test func retriesAtFallbackWhenPrimaryCannotBeReached() async throws {
        let client = try await makeClient()

        let token = try await client.login(password: "password")
        _ = try await client.login(password: "password")

        #expect(token == "fallback-token")
        #expect(FallbackTransport.requestedURLs.map(\.host) == [
            "primary.example.com", "fallback.example.com", "fallback.example.com"
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
}
