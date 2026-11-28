import Foundation
import Synchronization
import Testing
@testable import Actuali

/// The requests one client sent, body included.
private final class CapturedRequests: Sendable {
    let all = Mutex<[(request: URLRequest, body: Data)]>([])
}

struct EnableBankingClientTests {
    private func makeClient(
        serverURL: String = "https://budget.example.com",
        status: Int = 200,
        responseBody: String
    ) async throws -> (ActualServerClient, CapturedRequests) {
        let captured = CapturedRequests()
        let session = StubTransport.session { request in
            captured.all.withLock { $0.append((request, request.bodyData)) }
            return StubTransport.Response(
                status: status, contentType: "application/json", body: Data(responseBody.utf8)
            )
        }
        let client = ActualServerClient(session: session)
        try await client.configure(serverURL: serverURL)
        await client.setToken("test-token")
        return (client, captured)
    }

    private func sentBody(_ captured: CapturedRequests) throws -> [String: Any] {
        let body = try #require(captured.all.withLock { $0.first?.body })
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private let bank = #"{"name":"Nordea","country":"FI","psu_types":["personal","business"],"beta":false,"maximum_consent_validity":7776000}"#

    private func decodeBank(_ json: String) throws -> EnableBankingBank {
        try JSONDecoder().decode(EnableBankingBank.self, from: Data(json.utf8))
    }

    // MARK: status

    @Test(arguments: [true, false])
    func statusReportsWhetherTheServerIsConfigured(_ configured: Bool) async throws {
        let (client, captured) = try await makeClient(
            responseBody: #"{"status":"ok","data":{"configured":\#(configured)}}"#
        )

        #expect(try await client.enableBankingStatus() == configured)
        let (request, _) = try #require(captured.all.withLock { $0.first })
        #expect(request.url?.path == "/enablebanking/status")
        #expect(request.value(forHTTPHeaderField: "X-ACTUAL-TOKEN") == "test-token")
    }

    @Test func statusIsNilWhenTheRouteIsNotServed() async throws {
        let (client, _) = try await makeClient(status: 404, responseBody: "")

        #expect(try await client.enableBankingStatus() == nil)
    }

    @Test func statusWithoutTheFlagIsAnInvalidResponseNotAMissingRoute() async throws {
        let (client, _) = try await makeClient(responseBody: #"{"status":"ok"}"#)

        do {
            _ = try await client.enableBankingStatus()
            Issue.record("Expected enableBankingStatus to throw")
        } catch ActualServerError.invalidResponse {}
    }

    // MARK: banks

    @Test func banksAcceptsABareArray() async throws {
        let (client, captured) = try await makeClient(
            responseBody: #"{"status":"ok","data":[\#(bank)]}"#
        )

        let banks = try await client.enableBankingBanks(country: "FI")

        #expect(banks.map(\.name) == ["Nordea"])
        #expect(banks.first?.psuTypes == ["personal", "business"])
        #expect(banks.first?.maximumConsentValidity == 7_776_000)
        #expect(banks.first?.id == "FI:Nordea")
        #expect(try sentBody(captured)["country"] as? String == "FI")
    }

    @Test func banksAcceptsTheAspspsWrapper() async throws {
        let (client, _) = try await makeClient(
            responseBody: #"{"status":"ok","data":{"aspsps":[\#(bank)]}}"#
        )

        #expect(try await client.enableBankingBanks(country: "FI").map(\.name) == ["Nordea"])
    }

    @Test func banksSurfacesAnInBodyError() async throws {
        let (client, _) = try await makeClient(
            responseBody: #"{"status":"ok","data":{"error":"Country not supported"}}"#
        )

        await #expect(throws: EnableBankingAuthError.bankListFailed("Country not supported")) {
            _ = try await client.enableBankingBanks(country: "XX")
        }
    }

    // MARK: start authorization

    @Test func startSendsTheExpectedBodyAndDecodesTheAuthorization() async throws {
        let (client, captured) = try await makeClient(
            responseBody: #"{"status":"ok","data":{"url":"https://bank.example.com/auth","state":"s-1"}}"#
        )

        let authorization = try await client.enableBankingStartAuthorization(
            bank: decodeBank(bank), psuType: "personal"
        )

        #expect(authorization == EnableBankingAuthorization(
            url: URL(string: "https://bank.example.com/auth")!, state: "s-1"
        ))
        let (request, _) = try #require(captured.all.withLock { $0.first })
        #expect(request.url?.path == "/enablebanking/start-auth")
        let body = try sentBody(captured)
        #expect(body["aspsp"] as? [String: String] == ["name": "Nordea", "country": "FI"])
        #expect(body["redirectUrl"] as? String == "https://budget.example.com/enablebanking/auth_callback")
        #expect(body["psuType"] as? String == "personal")
        #expect(body["returnToApp"] as? Bool == false)
        #expect(body["maxConsentValidity"] as? Int == 7_776_000)
    }

    @Test func startOmitsAMissingOrOutOfRangeConsentValidity() async throws {
        let (client, captured) = try await makeClient(
            responseBody: #"{"status":"ok","data":{"url":"https://bank.example.com/auth","state":"s-1"}}"#
        )

        _ = try await client.enableBankingStartAuthorization(
            bank: decodeBank(#"{"name":"A","country":"FI"}"#), psuType: "business"
        )
        _ = try await client.enableBankingStartAuthorization(
            bank: decodeBank(#"{"name":"B","country":"FI","maximum_consent_validity":999999999999}"#),
            psuType: "business"
        )

        let bodies = try captured.all.withLock { $0.map(\.body) }.map {
            try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        #expect(bodies.count == 2)
        #expect(bodies.allSatisfy { $0["maxConsentValidity"] == nil })
    }

    @Test func startRefusesAServerWithoutHTTPS() async throws {
        let (client, captured) = try await makeClient(
            serverURL: "http://budget.example.com", responseBody: "{}"
        )

        await #expect(throws: EnableBankingAuthError.insecureServer) {
            _ = try await client.enableBankingStartAuthorization(bank: decodeBank(bank), psuType: "personal")
        }
        #expect(captured.all.withLock { $0.isEmpty })
    }

    @Test func startSurfacesAnInBodyError() async throws {
        let (client, _) = try await makeClient(
            responseBody: #"{"status":"ok","data":{"error_code":"INVALID_INPUT","error_type":"BAD_REQUEST"}}"#
        )

        await #expect(throws: EnableBankingAuthError.failed("BAD_REQUEST")) {
            _ = try await client.enableBankingStartAuthorization(bank: decodeBank(bank), psuType: "personal")
        }
    }

    // MARK: poll

    @Test func pollMapsAccountsOntoRemoteAccounts() async throws {
        let (client, captured) = try await makeClient(
            responseBody: """
            {"status":"ok","data":{"session_id":"x","aspsp":{},
             "accounts":[{"account_id":"uid-1","name":"Checking","institution":"Nordea","balance":12345}]}}
            """
        )

        let accounts = try await client.enableBankingPollAuthorization(state: "s-1", timeout: 280)

        let remote = try #require(accounts.first?.remoteAccount)
        #expect(remote.id == "uid-1")
        #expect(remote.institutionId == "uid-1")
        #expect(remote.institutionName == "Nordea")
        #expect(remote.balanceCents == 12345)
        #expect(remote.source == .enableBanking)
        let (request, _) = try #require(captured.all.withLock { $0.first })
        #expect(request.url?.path == "/enablebanking/poll-auth")
        #expect(request.value(forHTTPHeaderField: "X-ACTUAL-TOKEN") == "test-token")
        #expect(request.timeoutInterval == 280)
        #expect(try sentBody(captured)["state"] as? String == "s-1")
    }

    @Test func pollPutsTheGivenTimeoutOnTheRequest() async throws {
        let (client, captured) = try await makeClient(
            responseBody: #"{"status":"ok","data":{"session_id":"x","aspsp":{},"accounts":[]}}"#
        )

        _ = try await client.enableBankingPollAuthorization(state: "s-1", timeout: 42)

        let (request, _) = try #require(captured.all.withLock { $0.first })
        #expect(request.timeoutInterval == 42)
    }

    @Test func pollTimeoutMapsToTimedOut() async throws {
        let (client, _) = try await makeClient(
            responseBody: #"{"status":"ok","data":{"error":"Polling timed out"}}"#
        )

        await #expect(throws: EnableBankingAuthError.timedOut) {
            _ = try await client.enableBankingPollAuthorization(state: "s-1", timeout: 280)
        }
    }

    @Test func pollOtherErrorsMapToFailed() async throws {
        let (client, _) = try await makeClient(
            responseBody: #"{"status":"ok","data":{"error":"Authorization was denied"}}"#
        )

        await #expect(throws: EnableBankingAuthError.failed("Authorization was denied")) {
            _ = try await client.enableBankingPollAuthorization(state: "s-1", timeout: 280)
        }
    }

    /// The caller tells a poll worth repeating from one that isn't by the
    /// transport error inside.
    @Test func pollReportsATransportFailureWithItsCause() async throws {
        let session = StubTransport.session { _ in throw URLError(.networkConnectionLost) }
        let client = ActualServerClient(session: session)
        try await client.configure(serverURL: "https://budget.example.com")
        await client.setToken("test-token")

        let error = await #expect(throws: ActualServerError.self) {
            _ = try await client.enableBankingPollAuthorization(state: "s-1", timeout: 280)
        }
        guard case .networkError(let cause as URLError) = error else {
            Issue.record("expected a network error, got \(String(describing: error))")
            return
        }
        #expect(cause.code == .networkConnectionLost)
    }

    @Test(arguments: [401, 403])
    func pollWithARejectedSessionIsUnauthorized(_ status: Int) async throws {
        let (client, _) = try await makeClient(status: status, responseBody: #"{"status":"error","reason":"unauthorized"}"#)

        let error = await #expect(throws: ActualServerError.self) {
            _ = try await client.enableBankingPollAuthorization(state: "s-1", timeout: 280)
        }
        guard case .unauthorized = error else {
            Issue.record("expected unauthorized, got \(String(describing: error))")
            return
        }
    }
}
