// Actuali/Actuali/Services/Sync/HybridLogicalClock.swift

import Foundation

enum HLCError: Error, Equatable, LocalizedError {
    case clockDrift
    case counterOverflow
    case invalidTimestamp

    var errorDescription: String? {
        switch self {
        case .clockDrift:
            return String(localized: "Maximum clock drift exceeded. Check this device's date and time settings.")
        case .counterOverflow:
            return String(localized: "Timestamp counter overflow.")
        case .invalidTimestamp:
            return String(localized: "Timestamp is not valid.")
        }
    }
}

/// Hybrid Logical Clock for CRDT sync
/// Actor-isolated to ensure thread-safe timestamp generation
actor HybridLogicalClock {
    private var millis: Int64 = 0
    private var counter: UInt16 = 0
    nonisolated let node: String

    /// Maximum allowed clock drift (5 minutes, matching Actual)
    private let maxDrift: Int64 = 5 * 60 * 1000

    // MARK: - Initialization

    init(node: String? = nil) {
        self.node = node ?? Self.generateNodeId()
    }

    /// Initialize from a saved timestamp (for restoring state)
    init(from timestamp: HLCTimestamp) {
        self.millis = timestamp.millis
        self.counter = timestamp.counter
        self.node = timestamp.node
    }

    /// Generate a random 16-character hex node ID
    static func generateNodeId() -> String {
        UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .suffix(16)
            .lowercased()
    }

    // MARK: - Current State

    var current: HLCTimestamp {
        HLCTimestamp(millis: millis, counter: counter, node: node)
    }

    /// Advance the clock to at least the given timestamp, keeping our node id.
    /// Used to restore persisted state on startup (mirrors upstream setClock on
    /// budget load) so that `current` is never behind the local message
    /// high-water mark. Never moves the clock backwards.
    func advance(to timestamp: HLCTimestamp) {
        if timestamp.millis > millis || (timestamp.millis == millis && timestamp.counter > counter) {
            millis = timestamp.millis
            counter = timestamp.counter
        }
    }

    // MARK: - Send (local event)

    /// Generate a new timestamp for a local event
    /// Call this when creating local changes that will be synced
    func send() throws -> HLCTimestamp {
        let now = currentTimeMillis()

        // Calculate new logical time (never goes backward)
        let newMillis = max(millis, now)

        // Increment counter if time didn't advance (widened so the overflow
        // check below can observe 0x10000 instead of trapping)
        let newCounter: UInt32 = (millis == newMillis) ? UInt32(counter) + 1 : 0

        // Check for clock drift
        guard newMillis - now <= maxDrift else {
            throw HLCError.clockDrift
        }

        // Check for counter overflow
        guard newCounter <= 0xFFFF else {
            throw HLCError.counterOverflow
        }

        // Update state
        millis = newMillis
        counter = UInt16(newCounter)

        return HLCTimestamp(millis: millis, counter: counter, node: node)
    }

    // MARK: - Receive (remote event)

    /// Merge a remote timestamp to maintain causality
    /// Call this when receiving changes from sync
    @discardableResult
    func receive(_ remote: HLCTimestamp) throws -> HLCTimestamp {
        let now = currentTimeMillis()

        // Check for remote clock drift
        guard remote.millis - now <= maxDrift else {
            throw HLCError.clockDrift
        }

        // Calculate new logical time (max of local, remote, and wall clock)
        let newMillis = max(max(millis, now), remote.millis)

        // Calculate new counter based on which clock(s) are at newMillis
        // (widened so the overflow check below can observe 0x10000 instead of
        // trapping on a remote message carrying counter FFFF)
        let newCounter: UInt32
        if newMillis == millis && newMillis == remote.millis {
            // All three at same time - take max counter + 1
            newCounter = UInt32(max(counter, remote.counter)) + 1
        } else if newMillis == millis {
            // Local clock wins - increment local counter
            newCounter = UInt32(counter) + 1
        } else if newMillis == remote.millis {
            // Remote clock wins - increment remote counter
            newCounter = UInt32(remote.counter) + 1
        } else {
            // Wall clock wins - reset counter
            newCounter = 0
        }

        // Check for clock drift after calculation
        guard newMillis - now <= maxDrift else {
            throw HLCError.clockDrift
        }

        // Check for counter overflow
        guard newCounter <= 0xFFFF else {
            throw HLCError.counterOverflow
        }

        // Update state
        millis = newMillis
        counter = UInt16(newCounter)

        return HLCTimestamp(millis: millis, counter: counter, node: node)
    }

    // MARK: - Helpers

    private func currentTimeMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
