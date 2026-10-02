import Combine
import Foundation

/// Sync state and last-sync timestamp, kept off `BudgetStore` so that status
/// changes only invalidate the views displaying them (Settings' Sync section).
@MainActor
final class SyncStatus: ObservableObject {
    @Published var state: SyncState = .idle
    @Published var lastSyncTime: Date?
}
