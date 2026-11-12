import Foundation
import Testing
@testable import Actuali

struct OnDemandSearchTests {
    @Test(arguments: [
        (18, 5, false),
        (26, 0, true),
        (26, 4, true),
        (27, 0, false),
        (27, 2, false),
        (27, 3, true),
        (28, 0, true),
    ])
    func nativeSearchSkipsBrokenReleases(major: Int, minor: Int, expected: Bool) {
        let os = OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
        #expect(OnDemandSearchModifier.usesNativeSearch(os) == expected)
    }
}
