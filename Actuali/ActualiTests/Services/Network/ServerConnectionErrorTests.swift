import Foundation
import Testing
@testable import Actuali

/// Fails every request with a preset `URLError`, standing in for the transport
/// layer so we can prove connection failures reach the user as plain-English
/// guidance instead of CFNetwork's raw string.
private final class FailingTransport: URLProtocol {
    nonisolated(unsafe) static var failure = URLError(.secureConnectionFailed)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: Self.failure)
    }
    override func stopLoading() {}
}

/// A user whose server is unreachable only ever sees the message these tests
/// pin down, so each case asserts the wording actually names the cause and
/// points somewhere they can act on it.
@Suite(.serialized)
struct ServerConnectionErrorTests {
    private static let helpLink = "actuali.mfazz.com/support"

    /// Drives a real `login` through a transport that fails with `code`, and
    /// returns the error the app would see.
    private func loginFailure(_ code: URLError.Code) async -> (any Error)? {
        FailingTransport.failure = URLError(code)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingTransport.self]
        let client = ActualServerClient(session: URLSession(configuration: config))

        do {
            try await client.configure(serverURL: "https://budget.example.com")
            _ = try await client.login(password: "hunter2")
            Issue.record("Expected login to throw for \(code)")
            return nil
        } catch {
            return error
        }
    }

    /// The message the app would show for a login that fails with `code`.
    private func loginFailureMessage(_ code: URLError.Code) async -> String {
        await loginFailure(code)?.localizedDescription ?? ""
    }

    @Test func untrustedCertificateNamesTheCertificateAndLinksToHelp() async {
        let message = await loginFailureMessage(.secureConnectionFailed)
        #expect(message.localizedCaseInsensitiveContains("certificate"))
        #expect(message.contains(Self.helpLink))
    }

    @Test func expiredCertificateSaysItExpired() async {
        let message = await loginFailureMessage(.serverCertificateHasBadDate)
        #expect(message.localizedCaseInsensitiveContains("expired"))
        #expect(message.contains(Self.helpLink))
    }

    @Test func plainHTTPTellsTheUserToUseHTTPS() async {
        let message = await loginFailureMessage(.appTransportSecurityRequiresSecureConnection)
        #expect(message.contains("https://"))
    }

    @Test func unreachableHostMentionsTheLocalNetwork() async {
        let message = await loginFailureMessage(.cannotConnectToHost)
        #expect(message.localizedCaseInsensitiveContains("network"))
        #expect(message.contains(Self.helpLink))
    }

    @Test func missingHostAsksTheUserToCheckTheURL() async {
        let message = await loginFailureMessage(.cannotFindHost)
        #expect(message.localizedCaseInsensitiveContains("address"))
        #expect(message.contains(Self.helpLink))
        // Guards against matching "URL" inside a leaked "NSURLErrorDomain".
        #expect(!message.contains("NSURLErrorDomain"))
    }

    @Test func offlineDeviceBlamesTheInternetConnectionNotTheServer() async {
        let message = await loginFailureMessage(.notConnectedToInternet)
        #expect(message.localizedCaseInsensitiveContains("internet"))
    }

    /// Codes we don't map by hand still get the "couldn't connect" framing and
    /// the help link rather than a bare system string.
    @Test func unrecognisedTransportFailureStillOffersHelp() async {
        let message = await loginFailureMessage(.unknown)
        #expect(message.localizedCaseInsensitiveContains("connect"))
        #expect(message.contains(Self.helpLink))
    }

    /// Cancellation is ordinary control flow — a superseded refresh, a screen
    /// the user left — so it must reach callers untouched rather than being
    /// dressed up as a connection failure the user should worry about.
    @Test func cancellationIsNotReportedAsAConnectionFailure() async {
        let error = await loginFailure(.cancelled)
        #expect(!(error is ActualServerError))
        #expect((error as? URLError)?.code == .cancelled)
    }

    /// Server-side rejections must keep their existing wording — the friendly
    /// transport messages only apply to connection failures.
    @Test func httpErrorsKeepTheirExistingMessage() {
        let error = ActualServerError.httpError(statusCode: 403, message: "Forbidden")
        #expect(error.localizedDescription == "HTTP error 403: Forbidden")
    }
}
