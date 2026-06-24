import Foundation
import AuthenticationServices
import UIKit

enum OpenIDAuthError: LocalizedError {
    case cancelled
    case missingToken
    case server(String)
    case sessionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Sign-in was cancelled"
        case .missingToken:
            return "The server did not return a sign-in token"
        case .server(let reason):
            return "Sign-in failed: \(reason)"
        case .sessionFailed(let error):
            return "Sign-in failed: \(error.localizedDescription)"
        }
    }
}

/// Drives the OpenID/OAuth browser flow using `ASWebAuthenticationSession`.
///
/// The Actual server validates the `returnUrl` we hand it: its host must equal
/// the server's host or be `localhost`. A custom URL scheme whose host is
/// `localhost` (`actuali://localhost`) satisfies that check while remaining a
/// scheme that `ASWebAuthenticationSession` can intercept. After the provider
/// callback, the server redirects to `actuali://localhost/openid-cb?token=…`,
/// which this class captures to extract the Actual session token.
@MainActor
final class OpenIDAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// Scheme used for the callback URL. Must match the scheme in `returnURL`.
    static let callbackScheme = "actuali"
    /// `returnUrl` sent to the server. Host is `localhost` so it passes the
    /// server's `isValidRedirectUrl` check.
    static let returnURL = "\(callbackScheme)://localhost"

    private var session: ASWebAuthenticationSession?

    /// Present the provider's authorization page and wait for the callback.
    /// - Parameter authorizationURL: the OP authorization URL returned by the server.
    /// - Returns: the Actual session token from the callback's `token` query item.
    func authenticate(authorizationURL: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: Self.callbackScheme
            ) { callbackURL, error in
                if let error {
                    if let authError = error as? ASWebAuthenticationSessionError,
                       authError.code == .canceledLogin {
                        continuation.resume(throwing: OpenIDAuthError.cancelled)
                    } else {
                        continuation.resume(throwing: OpenIDAuthError.sessionFailed(error))
                    }
                    return
                }

                guard let callbackURL else {
                    continuation.resume(throwing: OpenIDAuthError.missingToken)
                    return
                }

                do {
                    let token = try Self.extractToken(from: callbackURL)
                    continuation.resume(returning: token)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            session.presentationContextProvider = self
            // Share Safari's session so a user already signed in to their identity
            // provider (e.g. Google) isn't forced to re-authenticate.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session

            if !session.start() {
                continuation.resume(throwing: OpenIDAuthError.sessionFailed(
                    NSError(domain: "OpenIDAuthenticator", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Could not start the sign-in session"])
                ))
            }
        }
    }

    /// Parse the `token` (or `error`) query item out of the server's callback URL,
    /// e.g. `actuali://localhost/openid-cb?token=…`.
    nonisolated static func extractToken(from url: URL) throws -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []

        if let error = items.first(where: { $0.name == "error" })?.value, !error.isEmpty {
            throw OpenIDAuthError.server(error)
        }
        guard let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty else {
            throw OpenIDAuthError.missingToken
        }
        return token
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}
