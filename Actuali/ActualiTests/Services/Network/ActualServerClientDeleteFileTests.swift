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

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequests.append(request)
        Self.capturedBodies.append(Self.readBody(request))

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
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
    private func makeClient(status: Int = 200) async throws -> ActualServerClient {
        DeleteFileTransport.capturedRequests = []
        DeleteFileTransport.capturedBodies = []
        DeleteFileTransport.status = status
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
    /// FIXME says it should be 404), so both map to `.fileNotFound`.
    @Test func mapsBadRequestToFileNotFound() async throws {
        for status in [400, 404] {
            let client = try await makeClient(status: status)
            do {
                try await client.deleteFile(fileId: "file-123")
                Issue.record("Expected deleteFile to throw for \(status)")
            } catch let error as ActualServerError {
                guard case .fileNotFound = error else {
                    Issue.record("Expected .fileNotFound for \(status), got \(error)")
                    return
                }
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
