import Foundation
import Testing
@testable import Actuali

/// Pins the detection engine. The ranking and the "every occurrence must
/// match" rule are what keep noise out of the proposals.
struct ScheduleDiscoveryTests {

    private func candidate(_ date: Int, _ amount: Int, payee: String = "p1") -> ScheduleDiscovery.Candidate {
        ScheduleDiscovery.Candidate(
            id: UUID().uuidString, date: DayDate(yyyymmdd: date)!,
            amount: amount, payeeId: payee, accountId: "acct-1")
    }

    private func monthlyConfig(_ start: Int) -> RecurConfig {
        RecurConfig(frequency: .monthly, start: DayDate(yyyymmdd: start)!)
    }

    @Test func thresholdIsSevenAndAHalfPercent() {
        #expect(ScheduleDiscovery.approxThreshold(-100_000) == 7500)
        #expect(ScheduleDiscovery.approxThreshold(0) == 0)
    }

    @Test func rankFallsOffWithDistance() {
        let a = DayDate(yyyymmdd: 20260815)!
        #expect(ScheduleDiscovery.rank(a, a) == 1.0)
        #expect(ScheduleDiscovery.rank(a, DayDate(yyyymmdd: 20260816)!) == 0.5)
        // Direction doesn't matter.
        #expect(ScheduleDiscovery.rank(a, DayDate(yyyymmdd: 20260814)!) == 0.5)
    }

    @Test func exactMonthlyRepeatIsDetected() {
        let occurrences = [
            (date: DayDate(yyyymmdd: 20260615)!, transactions: [candidate(20260615, -125_000)]),
            (date: DayDate(yyyymmdd: 20260715)!, transactions: [candidate(20260715, -125_000)]),
            (date: DayDate(yyyymmdd: 20260815)!, transactions: [candidate(20260815, -125_000)]),
        ]
        let matches = ScheduleDiscovery.match(
            occurrences: occurrences, config: monthlyConfig(20260615), accountId: "acct-1")

        #expect(matches.count == 1)
        let match = try! #require(matches.first)
        #expect(match.exactDate)
        #expect(match.exactAmount)
        #expect(match.rank == 3.0)
        #expect(match.amount == -125_000)
    }

    @Test func amountsWithinTheThresholdStillMatchButAreNotExact() {
        let occurrences = [
            (date: DayDate(yyyymmdd: 20260615)!, transactions: [candidate(20260615, -100_000)]),
            (date: DayDate(yyyymmdd: 20260715)!, transactions: [candidate(20260715, -103_000)]),
            (date: DayDate(yyyymmdd: 20260815)!, transactions: [candidate(20260815, -100_000)]),
        ]
        let match = try! #require(ScheduleDiscovery.match(
            occurrences: occurrences, config: monthlyConfig(20260615),
            accountId: "acct-1").first)
        #expect(!match.exactAmount)
        #expect(match.exactDate)
    }

    @Test func amountsOutsideTheThresholdDoNotMatch() {
        let occurrences = [
            (date: DayDate(yyyymmdd: 20260615)!, transactions: [candidate(20260615, -100_000)]),
            (date: DayDate(yyyymmdd: 20260715)!, transactions: [candidate(20260715, -150_000)]),
            (date: DayDate(yyyymmdd: 20260815)!, transactions: [candidate(20260815, -100_000)]),
        ]
        #expect(ScheduleDiscovery.match(
            occurrences: occurrences, config: monthlyConfig(20260615),
            accountId: "acct-1").isEmpty)
    }

    /// A gap in the middle disqualifies the pattern outright.
    @Test func aMissingOccurrenceDisqualifiesThePattern() {
        let occurrences = [
            (date: DayDate(yyyymmdd: 20260615)!, transactions: [candidate(20260615, -100_000)]),
            (date: DayDate(yyyymmdd: 20260715)!, transactions: [ScheduleDiscovery.Candidate]()),
            (date: DayDate(yyyymmdd: 20260815)!, transactions: [candidate(20260815, -100_000)]),
        ]
        #expect(ScheduleDiscovery.match(
            occurrences: occurrences, config: monthlyConfig(20260615),
            accountId: "acct-1").isEmpty)
    }

    @Test func differentPayeesDoNotMatchEachOther() {
        let occurrences = [
            (date: DayDate(yyyymmdd: 20260615)!, transactions: [candidate(20260615, -100_000, payee: "p1")]),
            (date: DayDate(yyyymmdd: 20260715)!, transactions: [candidate(20260715, -100_000, payee: "p2")]),
            (date: DayDate(yyyymmdd: 20260815)!, transactions: [candidate(20260815, -100_000, payee: "p1")]),
        ]
        #expect(ScheduleDiscovery.match(
            occurrences: occurrences, config: monthlyConfig(20260615),
            accountId: "acct-1").isEmpty)
    }

    @Test func datesThatDriftScoreLowerAndAreNotExact() {
        let occurrences = [
            (date: DayDate(yyyymmdd: 20260615)!, transactions: [candidate(20260616, -100_000)]),
            (date: DayDate(yyyymmdd: 20260715)!, transactions: [candidate(20260715, -100_000)]),
            (date: DayDate(yyyymmdd: 20260815)!, transactions: [candidate(20260815, -100_000)]),
        ]
        let match = try! #require(ScheduleDiscovery.match(
            occurrences: occurrences, config: monthlyConfig(20260615),
            accountId: "acct-1").first)
        #expect(!match.exactDate)
        #expect(match.rank == 2.5)
    }

    @Test func indexWindowsTwoDaysEitherSide() {
        let index = ScheduleDiscovery.CandidateIndex([
            candidate(20260813, -1), candidate(20260815, -2), candidate(20260818, -3),
        ])
        let near = index.near(DayDate(yyyymmdd: 20260815)!, days: 2)
        #expect(near.count == 2)   // the 13th and the 15th; the 18th is outside
    }

    @Test func proposalOperatorsFollowHowExactlyItMatched() {
        let proposal = ScheduleDiscovery.Proposal(
            accountId: "acct-1", payeeId: "p1", amount: -100_000,
            config: monthlyConfig(20260615), exactDate: true, exactAmount: false)
        #expect(proposal.formFields.amountOp == .isApprox)
        #expect(proposal.formFields.postsTransaction == false)
    }
}
