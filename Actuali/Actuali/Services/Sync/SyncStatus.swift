import Combine
import Foundation

@MainActor
final class SyncStatus: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private(set) var state: SyncState = .idle
    private(set) var lastSyncTime: Date?

    /// State and timestamp can change together without publishing twice.
    func update(state: SyncState, lastSyncTime: Date?) {
        guard self.state != state || self.lastSyncTime != lastSyncTime else { return }
        objectWillChange.send()
        self.state = state
        self.lastSyncTime = lastSyncTime
    }
}
