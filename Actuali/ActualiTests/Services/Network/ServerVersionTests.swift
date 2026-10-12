import Testing
@testable import Actuali

struct ServerVersionTests {
    @Test(arguments: [
        ("26.9.0", true), ("26.10.1", true), ("27.0.0", true),
        ("26.8.1", false), ("25.12.0", false), ("garbage", false),
    ])
    func accountGroupsGate(version: String, expected: Bool) {
        #expect(ServerVersion.supportsAccountGroups(version) == expected)
    }

    @Test func accountGroupsGateTreatsNilAsUnsupported() {
        #expect(ServerVersion.supportsAccountGroups(nil) == false)
    }
}
