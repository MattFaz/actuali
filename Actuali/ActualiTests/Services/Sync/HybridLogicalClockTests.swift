import Foundation
import Testing
@testable import Actuali

struct HybridLogicalClockTests {

    private func nowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// A logical time slightly ahead of the wall clock but well inside the
    /// 5-minute drift window, so send()/receive() take the same-millisecond
    /// (counter-increment) path deterministically.
    private func aheadMillis() -> Int64 {
        nowMillis() + 60_000
    }

    // MARK: - Counter overflow (actios-ost)

    @Test func sendThrowsOnCounterOverflow() async throws {
        let clock = HybridLogicalClock(
            from: HLCTimestamp(millis: aheadMillis(), counter: 0xFFFF, node: "aaaaaaaaaaaaaaaa")
        )
        await #expect(throws: HLCError.counterOverflow) {
            try await clock.send()
        }
    }

    @Test func sendSucceedsAtCounterBoundary() async throws {
        let millis = aheadMillis()
        let clock = HybridLogicalClock(
            from: HLCTimestamp(millis: millis, counter: 0xFFFE, node: "aaaaaaaaaaaaaaaa")
        )
        let ts = try await clock.send()
        #expect(ts.counter == 0xFFFF)
        #expect(ts.millis == millis)
    }

    @Test func receiveThrowsWhenRemoteCounterOverflows() async throws {
        let clock = HybridLogicalClock(node: "aaaaaaaaaaaaaaaa")
        let remote = HLCTimestamp(millis: aheadMillis(), counter: 0xFFFF, node: "bbbbbbbbbbbbbbbb")
        await #expect(throws: HLCError.counterOverflow) {
            try await clock.receive(remote)
        }
    }

    @Test func receiveThrowsWhenLocalCounterOverflows() async throws {
        let millis = aheadMillis()
        let clock = HybridLogicalClock(
            from: HLCTimestamp(millis: millis, counter: 0xFFFF, node: "aaaaaaaaaaaaaaaa")
        )
        let remote = HLCTimestamp(millis: millis, counter: 5, node: "bbbbbbbbbbbbbbbb")
        await #expect(throws: HLCError.counterOverflow) {
            try await clock.receive(remote)
        }
    }

    @Test func receiveResetsCounterWhenWallClockWins() async throws {
        // Remote at max counter but in the past: wall clock wins, counter
        // resets to 0 - must not throw.
        let clock = HybridLogicalClock(node: "aaaaaaaaaaaaaaaa")
        let remote = HLCTimestamp(millis: nowMillis() - 60_000, counter: 0xFFFF, node: "bbbbbbbbbbbbbbbb")
        let ts = try await clock.receive(remote)
        #expect(ts.counter == 0)
        #expect(ts > remote)
    }

    // MARK: - Relaunch monotonicity (actios-917)

    /// Simulates the configure() seeding path: a fresh clock (new launch) is
    /// advanced to the max pre-existing message timestamp. The first send()
    /// must sort strictly after that maximum, including the same-millisecond
    /// case where only the counter can break the tie. The seeded node sorts
    /// after ours so a counter reset to 0 would fail this test.
    @Test func firstSendAfterRelaunchSortsAfterSeededMaximum() async throws {
        let maxSeen = HLCTimestamp(millis: aheadMillis(), counter: 7, node: "ffffffffffffffff")
        let clock = HybridLogicalClock(node: "0000000000000000")
        await clock.advance(to: maxSeen)

        let ts = try await clock.send()
        #expect(ts > maxSeen)
        #expect(ts.millis == maxSeen.millis)
        #expect(ts.counter == maxSeen.counter + 1)
    }

    @Test func firstSendAfterRelaunchSortsAfterPastSeededMaximum() async throws {
        // Seeded high-water mark in the past: wall clock advances millis,
        // which alone guarantees strict ordering.
        let maxSeen = HLCTimestamp(millis: nowMillis() - 60_000, counter: 42, node: "ffffffffffffffff")
        let clock = HybridLogicalClock(node: "0000000000000000")
        await clock.advance(to: maxSeen)

        let ts = try await clock.send()
        #expect(ts > maxSeen)
        #expect(ts.millis > maxSeen.millis)
    }

    @Test func advanceRestoresCounterAndNeverMovesBackwards() async throws {
        let clock = HybridLogicalClock(node: "0000000000000000")
        let high = HLCTimestamp(millis: 1_000_000, counter: 9, node: "ffffffffffffffff")
        await clock.advance(to: high)
        var current = await clock.current
        #expect(current.millis == 1_000_000)
        #expect(current.counter == 9)

        // Lower candidate (same millis, lower counter) must be ignored.
        await clock.advance(to: HLCTimestamp(millis: 1_000_000, counter: 3, node: "ffffffffffffffff"))
        current = await clock.current
        #expect(current.counter == 9)

        // Lower millis must be ignored.
        await clock.advance(to: HLCTimestamp(millis: 999_999, counter: 0xFFFF, node: "ffffffffffffffff"))
        current = await clock.current
        #expect(current.millis == 1_000_000)
        #expect(current.counter == 9)
    }

    /// Seeding at the counter boundary: the very next same-millisecond send()
    /// overflows and must throw (matching upstream), not trap.
    @Test func sendAfterSeedingAtCounterBoundaryThrows() async throws {
        let maxSeen = HLCTimestamp(millis: aheadMillis(), counter: 0xFFFF, node: "ffffffffffffffff")
        let clock = HybridLogicalClock(node: "0000000000000000")
        await clock.advance(to: maxSeen)
        await #expect(throws: HLCError.counterOverflow) {
            try await clock.send()
        }
    }
}
