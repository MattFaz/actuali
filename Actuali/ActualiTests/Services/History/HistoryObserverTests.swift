import Testing
@testable import Actuali

@MainActor
struct HistoryObserverTests {
    @Test func marksRefreshRemoteOnlyWhenSyncTransitionsToIdle() {
        #expect(HistoryObserver.shouldMarkRemoteRefresh(wasSyncing: true, state: .idle))
        #expect(!HistoryObserver.shouldMarkRemoteRefresh(wasSyncing: false, state: .idle))
        #expect(!HistoryObserver.shouldMarkRemoteRefresh(wasSyncing: true, state: .syncing))
    }

    @Test func reloadSignalResetsHistoryBaseline() {
        #expect(HistoryObserver.shouldResetBaselineForReload(isLoading: true))
        #expect(!HistoryObserver.shouldResetBaselineForReload(isLoading: false))
    }
}
