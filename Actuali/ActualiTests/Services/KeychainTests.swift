import Foundation
import Testing
@testable import Actuali

struct KeychainTests {
    /// A reinstall forgets every budget's encryption key by prefix; nothing
    /// else in the Keychain (a SimpleFIN key, custom headers) may go with it.
    @Test func removeAllWithPrefixLeavesOtherItemsAlone() throws {
        let prefix = "keychain-test-\(UUID().uuidString)."
        let other = "keychain-test-other-\(UUID().uuidString)"
        defer { try? Keychain.remove(for: other) }
        try Keychain.set("a", for: prefix + "one")
        try Keychain.set("b", for: prefix + "two")
        try Keychain.set("c", for: other)

        Keychain.removeAll(withPrefix: prefix)

        #expect(Keychain.get(for: prefix + "one") == nil)
        #expect(Keychain.get(for: prefix + "two") == nil)
        #expect(Keychain.get(for: other) == "c")
    }
}
