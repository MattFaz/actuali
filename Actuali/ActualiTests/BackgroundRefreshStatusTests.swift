import Foundation
import Testing
@testable import Actuali

struct BackgroundRefreshStatusTests {

    private func makeDefaults() -> UserDefaults {
        let name = "BackgroundRefreshStatusTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func nilBeforeFirstRun() {
        let status = BackgroundRefreshStatus(defaults: makeDefaults())

        #expect(status.lastRun == nil)
    }

    @Test func lastRunPersistsAcrossInstances() {
        let defaults = makeDefaults()
        let fired = Date(timeIntervalSince1970: 1_700_000_000)

        BackgroundRefreshStatus(defaults: defaults).lastRun = fired

        #expect(BackgroundRefreshStatus(defaults: defaults).lastRun == fired)
    }
}
