import Foundation
import Testing
import BackgroundTasks
@testable import Actuali

struct BackgroundRefreshTests {

    /// Registering a BGTask identifier that is not listed in
    /// BGTaskSchedulerPermittedIdentifiers crashes at launch, so guard the
    /// Info.plist against drifting from the code constant.
    @Test func taskIdentifierIsPermittedByInfoPlist() {
        let permitted = Bundle.main.object(
            forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        #expect(permitted?.contains(BackgroundRefresh.taskIdentifier) == true)
    }

    @Test func backgroundModesIncludeFetch() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        #expect(modes?.contains("fetch") == true)
    }

    @Test func makeRequestSetsIdentifierAndEarliestBeginDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let request = BackgroundRefresh.makeRequest(now: now)

        #expect(request.identifier == BackgroundRefresh.taskIdentifier)
        #expect(request.earliestBeginDate == now.addingTimeInterval(BackgroundRefresh.minimumInterval))
    }

    @Test func scheduleSubmitsOneRequestWithTaskIdentifier() {
        let spy = SubmitSpy()

        BackgroundRefresh.schedule(using: spy, now: Date(timeIntervalSince1970: 0))

        #expect(spy.submitted.map(\.identifier) == [BackgroundRefresh.taskIdentifier])
    }

    /// BGTaskScheduler.submit throws in environments where background tasks
    /// are unavailable (e.g. simulator); scheduling must never take the app down.
    @Test func scheduleSwallowsSubmitErrors() {
        let spy = SubmitSpy()
        spy.error = NSError(domain: "test", code: 1)

        BackgroundRefresh.schedule(using: spy, now: Date(timeIntervalSince1970: 0))

        #expect(spy.submitted.isEmpty)
    }
}

private final class SubmitSpy: BackgroundTaskRequesting {
    var submitted: [BGTaskRequest] = []
    var error: Error?

    func submit(_ taskRequest: BGTaskRequest) throws {
        if let error { throw error }
        submitted.append(taskRequest)
    }
}
