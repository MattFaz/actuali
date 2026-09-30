import Foundation
import Synchronization
import Testing
@testable import Actuali

/// The delete-user-file requests one client sent, body included.
private final class CapturedRequests: Sendable {
    let all = Mutex<[(request: URLRequest, body: Data)]>([])
}

struct ActualServerClientDeleteFileTests {
    private func makeClient(
        status: Int = 200,
        responseBody: String = #"{"status":"ok"}"#,
        responseContentType: String = "application/json"
    ) async throws -> (ActualServerClient, CapturedRequests) {
        let captured = CapturedRequests()
        let session = StubTransport.session { request in
            captured.all.withLock { $0.append((request, request.bodyData)) }
            return StubTransport.Response(
                status: status, contentType: responseContentType, body: Data(responseBody.utf8)
            )
        }
        let client = ActualServerClient(session: session)
        try await client.configure(serverURL: "https://budget.example.com")
        await client.setToken("test-token")
        return (client, captured)
    }

    /// Upstream's removeFile POSTs `{token, fileId}` to /delete-user-file
    /// (cloud-storage.ts); the header carries the token like our other routes.
    @Test func postsTokenAndFileIdToDeleteUserFile() async throws {
        let (client, captured) = try await makeClient()

        try await client.deleteFile(fileId: "file-123")

        let (request, body) = try #require(captured.all.withLock { $0.first })
        #expect(request.url?.path == "/sync/delete-user-file")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-ACTUAL-TOKEN") == "test-token")
        #expect(try JSONDecoder().decode([String: String].self, from: body)
            == ["token": "test-token", "fileId": "file-123"])
    }

    @Test func requiresAToken() async throws {
        let (client, captured) = try await makeClient()
        await client.setToken(nil)

        await #expect(throws: ActualServerError.self) {
            try await client.deleteFile(fileId: "file-123")
        }
        #expect(captured.all.withLock { $0.isEmpty })
    }

    @Test func mapsForbiddenToUnauthorized() async throws {
        let (client, _) = try await makeClient(status: 403)

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
        let (client, _) = try await makeClient(status: 400, responseBody: "file-not-found")
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
        let (client, _) = try await makeClient(status: 400, responseBody: "invalid fileId")
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
        let (client, _) = try await makeClient(status: 404)
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
        let (client, _) = try await makeClient(
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
        let (client, _) = try await makeClient(status: 500)

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
