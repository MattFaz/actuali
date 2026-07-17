import Foundation
import Testing
@testable import Actuali

/// Wiring-level tests for auto-posting of scheduled transactions (Task 7):
/// the success Bool `automaticSync()` now returns, and the toast copy.
///
/// Not covered here, deliberately:
/// - `automaticSync() == true` on success and on the rate-limited skip both
///   require a sync that actually SUCCEEDS (the skip only fires when
///   `lastSuccessfulSyncTime` is recent, and that is set only by a successful
///   `performSync()`), which means a live server or transport-level mock the
///   test suite doesn't have — no existing SyncClient test runs a successful
///   full sync. Building that scaffolding is out of scope for this task.
/// - Toggle/toast UI behavior (Task 8 E2E).
struct SchedulePostingWiringTests {

    /// A failed sync must report false — an unconfigured client fails fast
    /// and locally (SyncError.notConfigured), the same failure funnel as any
    /// network error.
    @Test func automaticSyncReturnsFalseWhenSyncFails() async {
        let client = SyncClient(serverClient: ActualServerClient(), nodeId: "89e0e8e90b203f9e")
        let success = await client.automaticSync()
        #expect(success == false)
    }

    @MainActor
    @Test func schedulePostNoticePluralizes() {
        #expect(BudgetStore.schedulePostNoticeText(count: 1) == "Posted 1 scheduled transaction")
        #expect(BudgetStore.schedulePostNoticeText(count: 2) == "Posted 2 scheduled transactions")
    }
}
