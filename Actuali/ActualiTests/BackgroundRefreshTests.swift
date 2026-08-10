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

    /// The hint is only a floor — iOS schedules at its own discretion — so a
    /// low floor gives the system more windows to pick from.
    @Test func minimumIntervalIsOneHour() {
        #expect(BackgroundRefresh.minimumInterval == 60 * 60)
    }

    @Test func scheduleRecordsAttemptTimeAndClearsPreviousError() {
        let spy = SubmitSpy()
        let defaults = makeIsolatedDefaults()
        let status = BackgroundRefreshStatus(defaults: defaults)
        status.lastScheduleError = "stale failure"
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        BackgroundRefresh.schedule(using: spy, now: now, defaults: defaults)

        #expect(status.lastScheduleAttempt == now)
        #expect(status.lastScheduleError == nil)
    }

    /// "We asked and iOS said no" must be distinguishable from "we never
    /// asked" — that ambiguity is what makes Never-style bugs undebuggable.
    @Test func scheduleRecordsErrorWhenSubmitFails() {
        let spy = SubmitSpy()
        spy.error = NSError(domain: "test", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "refresh unavailable"])
        let defaults = makeIsolatedDefaults()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        BackgroundRefresh.schedule(using: spy, now: now, defaults: defaults)

        let status = BackgroundRefreshStatus(defaults: defaults)
        #expect(status.lastScheduleAttempt == now)
        #expect(status.lastScheduleError == "refresh unavailable")
    }

    @Test func handleReschedulesStampsWakeAndCompletesWithSyncResult() async {
        let spy = SubmitSpy()
        let defaults = makeIsolatedDefaults()
        let task = TaskSpy()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        await BackgroundRefresh.handle(task, scheduler: spy, now: now,
                                       defaults: defaults) { true }.value

        #expect(spy.submitted.map(\.identifier) == [BackgroundRefresh.taskIdentifier])
        #expect(BackgroundRefreshStatus(defaults: defaults).lastRun == now)
        #expect(task.completions == [true])
    }

    @Test func handleExpirationCancelsSyncAndStillCompletes() async {
        let task = TaskSpy()
        let defaults = makeIsolatedDefaults()

        let work = BackgroundRefresh.handle(task, scheduler: SubmitSpy(),
                                            now: Date(timeIntervalSince1970: 0),
                                            defaults: defaults) {
            // The expiration handler must already be wired when sync starts;
            // spin until its cancellation reaches us.
            #expect(task.expirationHandler != nil)
            while !Task.isCancelled { await Task.yield() }
            return false
        }
        task.expirationHandler?()
        await work.value

        #expect(task.completions == [false])
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "BackgroundRefreshTests-\(UUID().uuidString)")!
        defaults.removePersistentDomain(forName: defaults.description)
        return defaults
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

private final class TaskSpy: BackgroundRefreshTask {
    var expirationHandler: (() -> Void)?
    var completions: [Bool] = []

    func setTaskCompleted(success: Bool) { completions.append(success) }
}
