import Foundation
import os

private let logger = Logger(subsystem: "com.mfazz.Actuali", category: "SimpleFIN")

/// Where the claimed SimpleFIN access key lives.
///
/// The Keychain, not `@AppStorage`: the key is a bearer credential for the
/// person's bank data, and `kSecAttrAccessibleAfterFirstUnlock` (Keychain's
/// default here) is what lets a background refresh read it.
///
/// One key per device, not per budget file — a SimpleFIN setup token is
/// claimed once and can't be claimed again, so tying it to a budget file
/// would strand it when the file is re-downloaded.
enum SimpleFINCredentials {
    private static let accessKeyItem = "simplefin-access-key"

    /// The stored access key, or nil when SimpleFIN isn't set up (or what's
    /// stored is no longer parseable).
    static var accessKey: SimpleFINAccessKey? {
        guard let raw = Keychain.get(for: accessKeyItem) else { return nil }
        do {
            return try SimpleFINAccessKey.parse(raw)
        } catch {
            logger.error("Stored SimpleFIN access key is unreadable")
            return nil
        }
    }

    static var isConfigured: Bool { Keychain.get(for: accessKeyItem) != nil }

    static func save(_ accessKey: SimpleFINAccessKey) throws {
        try Keychain.set(accessKey.raw, for: accessKeyItem)
    }

    static func clear() throws {
        try Keychain.remove(for: accessKeyItem)
    }
}
