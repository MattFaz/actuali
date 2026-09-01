import Foundation
import Testing
@testable import Actuali

/// Captures delete-user-file requests and answers with a preset status, so the
/// client's request shape and error mapping can be pinned down offline.
private final class DeleteFileTransport: URLProtocol {
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []
    nonisolated(unsafe) static var capturedBodies: [Data] = []
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data(#"{"status":"ok"}"#.utf8)
    nonisolated(unsafe) static var responseContentType = "application/json"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequests.append(request)
        Self.capturedBodies.append(Self.readBody(request))

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": Self.responseContentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands POST bodies to URLProtocol as a stream, not httpBody.
    private static func readBody(_ request: URLRequest) -> Data {
        guard let stream = request.httpBodyStream else { return request.httpBody ?? Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        let bufferSize = 16 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            body.append(buffer, count: read)
        }
        return body
    }
}

@Suite(.serialized)
struct ActualServerClientDeleteFileTests {
    private func makeClient(
        status: Int = 200,
        responseBody: String = #"{"status":"ok"}"#,
        responseContentType: String = "application/json"
    ) async throws -> ActualServerClient {
        DeleteFileTransport.capturedRequests = []
        DeleteFileTransport.capturedBodies = []
        DeleteFileTransport.status = status
        DeleteFileTransport.responseBody = Data(responseBody.utf8)
        DeleteFileTransport.responseContentType = responseContentType
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeleteFileTransport.self]
        let client = ActualServerClient(session: URLSession(configuration: configuration))
        try await client.configure(serverURL: "https://budget.example.com")
        await client.setToken("test-token")
        return client
    }

    /// Upstream's removeFile POSTs `{token, fileId}` to /delete-user-file
    /// (cloud-storage.ts); the header carries the token like our other routes.
    @Test func postsTokenAndFileIdToDeleteUserFile() async throws {
        let client = try await makeClient()

        try await client.deleteFile(fileId: "file-123")

        let request = try #require(DeleteFileTransport.capturedRequests.first)
        #expect(request.url?.path == "/sync/delete-user-file")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-ACTUAL-TOKEN") == "test-token")
        let body = try JSONDecoder().decode(
            [String: String].self,
            from: try #require(DeleteFileTransport.capturedBodies.first)
        )
        #expect(body == ["token": "test-token", "fileId": "file-123"])
    }

    @Test func requiresAToken() async throws {
        let client = try await makeClient()
        await client.setToken(nil)

        await #expect(throws: ActualServerError.self) {
            try await client.deleteFile(fileId: "file-123")
        }
        #expect(DeleteFileTransport.capturedRequests.isEmpty)
    }

    @Test func mapsForbiddenToUnauthorized() async throws {
        let client = try await makeClient(status: 403)

        do {
            try await client.deleteFile(fileId: "file-123")
            Issue.record("Expected deleteFile to throw")
        } catch let error as ActualServerError {
            guard case .unauthorized = error else {
                Issue.record("Expected .unauthorized, got \(error)")
                return
            }
        }
    }

    /// The server answers an unknown fileId with 400 file-not-found (its own
    /// FIXME says it should be 404).
    @Test func mapsBadRequestToFileNotFound() async throws {
        let client = try await makeClient(status: 400, responseBody: "file-not-found")
        do {
            try await client.deleteFile(fileId: "file-123")
            Issue.record("Expected deleteFile to throw")
        } catch let error as ActualServerError {
            guard case .fileNotFound = error else {
                Issue.record("Expected .fileNotFound, got \(error)")
                return
            }
        }
    }

    @Test func keepsOtherBadRequestsAsHTTPErrors() async throws {
        let client = try await makeClient(status: 400, responseBody: "invalid fileId")
        do {
            try await client.deleteFile(fileId: "budget@2026")
            Issue.record("Expected deleteFile to throw")
        } catch let error as ActualServerError {
            guard case .httpError(let statusCode, _) = error else {
                Issue.record("Expected .httpError, got \(error)")
                return
            }
            #expect(statusCode == 400)
        }
    }

    /// The Actual server never answers a missing file with 404 — that status
    /// means a proxy or a stripped route. It must NOT map to .fileNotFound,
    /// which callers treat as "already deleted" before destroying local data.
    @Test func keeps404AsAPlainHTTPError() async throws {
        let client = try await makeClient(status: 404)
        do {
            try await client.deleteFile(fileId: "file-123")
            Issue.record("Expected deleteFile to throw")
        } catch let error as ActualServerError {
            guard case .httpError(let statusCode, _) = error else {
                Issue.record("Expected .httpError, got \(error)")
                return
            }
            #expect(statusCode == 404)
        }
    }

    /// An auth proxy's HTML login page is named as such rather than surfacing
    /// as a decode failure — or worse, a status that callers act on.
    @Test func namesAnAuthProxyAnswer() async throws {
        let client = try await makeClient(
            status: 200,
            responseBody: "<html><body>Sign in</body></html>",
            responseContentType: "text/html"
        )
        do {
            try await client.deleteFile(fileId: "file-123")
            Issue.record("Expected deleteFile to throw")
        } catch let error as ActualServerError {
            guard case .authProxyBlocked = error else {
                Issue.record("Expected .authProxyBlocked, got \(error)")
                return
            }
        }
    }

    @Test func surfacesOtherServerFailuresAsHTTPErrors() async throws {
        let client = try await makeClient(status: 500)

        do {
            try await client.deleteFile(fileId: "file-123")
            Issue.record("Expected deleteFile to throw")
        } catch let error as ActualServerError {
            guard case .httpError(let statusCode, _) = error else {
                Issue.record("Expected .httpError, got \(error)")
                return
            }
            #expect(statusCode == 500)
        }
    }
}
