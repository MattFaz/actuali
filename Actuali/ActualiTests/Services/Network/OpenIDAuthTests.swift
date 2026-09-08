import Foundation
import Testing
@testable import Actuali

struct OpenIDAuthTests {

    private var actualiBundle: Bundle {
        Bundle(identifier: "com.mfazz.ActualiOS")!
    }

    @Test func sessionStartFailureDescriptionUsesFrenchAppLocalization() {
        let frenchBundlePath = actualiBundle.path(forResource: "fr", ofType: "lproj")
        #expect(frenchBundlePath != nil)

        let description = OpenIDAuthError.sessionStartFailureDescription(
            locale: Locale(identifier: "fr_FR"),
            bundle: actualiBundle
        )

        #expect(description == "Impossible de démarrer la session de connexion")

        let error = NSError(
            domain: "OpenIDAuthenticator",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
        #expect(error.localizedDescription == "Impossible de démarrer la session de connexion")
    }

    @Test func adjacentOpenIDErrorsRemainLocalizedByTheAppAtRuntime() {
        #expect(OpenIDAuthError.cancelled.errorDescription == "Sign-in was cancelled")
        #expect(OpenIDAuthError.missingToken.errorDescription == "The server did not return a sign-in token")
        #expect(OpenIDAuthError.noWindow.errorDescription == "Sign-in needs an open window. Try again with the app in the foreground.")
        #expect(OpenIDAuthError.server("access_denied").errorDescription == "Sign-in failed: access_denied")
    }

    // MARK: - Callback token extraction

    @Test func extractsTokenFromCallbackURL() throws {
        let url = URL(string: "actuali://localhost/openid-cb?token=abc123")!
        let token = try OpenIDAuthenticator.extractToken(from: url)
        #expect(token == "abc123")
    }

    @Test func extractsTokenIgnoringOtherQueryItems() throws {
        let url = URL(string: "actuali://localhost/openid-cb?foo=bar&token=xyz&baz=1")!
        let token = try OpenIDAuthenticator.extractToken(from: url)
        #expect(token == "xyz")
    }

    @Test func throwsServerErrorWhenCallbackHasError() {
        let url = URL(string: "actuali://localhost/openid-cb?error=access_denied")!
        #expect(throws: OpenIDAuthError.self) {
            try OpenIDAuthenticator.extractToken(from: url)
        }
    }

    @Test func throwsMissingTokenWhenAbsent() {
        let url = URL(string: "actuali://localhost/openid-cb")!
        #expect(throws: OpenIDAuthError.self) {
            try OpenIDAuthenticator.extractToken(from: url)
        }
    }

    @Test func throwsMissingTokenWhenEmpty() {
        let url = URL(string: "actuali://localhost/openid-cb?token=")!
        #expect(throws: OpenIDAuthError.self) {
            try OpenIDAuthenticator.extractToken(from: url)
        }
    }

    /// The returnURL we send must have host `localhost` so the server's
    /// isValidRedirectUrl check passes, and its scheme must match the callback scheme.
    @Test func returnURLUsesLocalhostHostAndMatchingScheme() throws {
        let url = try #require(URL(string: OpenIDAuthenticator.returnURL))
        #expect(url.host == "localhost")
        #expect(url.scheme == OpenIDAuthenticator.callbackScheme)
    }

    // MARK: - Response decoding

    @Test func decodesLoginMethods() throws {
        let json = """
        {"status":"ok","methods":[
          {"method":"password","displayName":"Password","active":1},
          {"method":"openid","displayName":"OpenID","active":1}
        ]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LoginMethodsResponse.self, from: json)
        #expect(decoded.methods?.count == 2)
        #expect(decoded.methods?.first?.method == "password")
        #expect(decoded.methods?.allSatisfy { $0.isActive } == true)
    }

    @Test func inactiveLoginMethodReportsNotActive() throws {
        let json = """
        {"status":"ok","methods":[{"method":"openid","displayName":"OpenID","active":0}]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LoginMethodsResponse.self, from: json)
        #expect(decoded.methods?.first?.isActive == false)
    }

    @Test func decodesOpenIDInitResponse() throws {
        let json = """
        {"status":"ok","data":{"returnUrl":"https://idp.example.com/authorize?client_id=x&state=y"}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OpenIDInitResponse.self, from: json)
        #expect(decoded.status == "ok")
        #expect(decoded.data?.returnUrl.hasPrefix("https://idp.example.com") == true)
    }

    @Test func decodesOpenIDInitErrorReason() throws {
        let json = """
        {"status":"error","reason":"invalid-return-url"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OpenIDInitResponse.self, from: json)
        #expect(decoded.status == "error")
        #expect(decoded.reason == "invalid-return-url")
        #expect(decoded.data == nil)
    }
}
