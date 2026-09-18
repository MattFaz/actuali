@testable import Actuali
import Foundation
import Testing

/// Pins the detection engine. The ranking and the "every occurrence must
/// match" rule are what keep noise out of the proposals.
struct ScheduleDiscoveryTests {
    private func candidate(_ date: Int, _ amount: Int, payee: String = "p1") -> ScheduleDiscovery.Candidate {
        ScheduleDiscovery.Candidate(
            id: UUID().uuidString, date: DayDate(yyyymmdd: date)!,
            amount: amount, payeeId: payee, accountId: "acct-1"
        )
    }

    private func monthlyConfig(_ start: Int) -> RecurConfig {
        RecurConfig(frequency: .monthly, start: DayDate(yyyymmdd: start)!)
    }

    @Test func thresholdIsSevenAndAHalfPercent() {
        #expect(ScheduleDiscovery.approxThreshold(-100_000) == 7500)
        #expect(ScheduleDiscovery.approxThreshold(0) == 0)
    }

    @Test func rankFallsOffWithDistance() throws {
        let a = try #require(DayDate(yyyymmdd: 20_260_815))
        #expect(ScheduleDiscovery.rank(a, a) == 1.0)
        #expect(try ScheduleDiscovery.rank(a, #require(DayDate(yyyymmdd: 20_260_816))) == 0.5)
        // Direction doesn't matter.
        #expect(try ScheduleDiscovery.rank(a, #require(DayDate(yyyymmdd: 20_260_814))) == 0.5)
    }

    @Test func exactMonthlyRepeatIsDetected() throws {
        let occurrences = try [
            (date: #require(DayDate(yyyymmdd: 20_260_615)), transactions: [candidate(20_260_615, -125_000)]),
            (date: #require(DayDate(yyyymmdd: 20_260_715)), transactions: [candidate(20_260_715, -125_000)]),
            (date: #require(DayDate(yyyymmdd: 20_260_815)), transactions: [candidate(20_260_815, -125_000)])
        ]
        let matches = ScheduleDiscovery.match(
            occurrences: occurrences, config: monthlyConfig(20_260_615), accountId: "acct-1"
        )

        #expect(matches.count == 1)
        let match = try #require(matches.first)
        #expect(match.exactDate)
        #expect(match.exactAmount)
        #expect(match.rank == 3.0)
        #expect(match.amount == -125_000)
    }

    @Test func amountsWithinTheThresholdStillMatchButAreNotExact() throws {
        let occurrences = try [
            (date: #require(DayDate(yyyymmdd: 20_260_615)), transactions: [candidate(20_260_615, -100_000)]),
            (date: #require(DayDate(yyyymmdd: 20_260_715)), transactions: [candidate(20_260_715, -103_000)]),
            (date: #require(DayDate(yyyymmdd: 20_260_815)), transactions: [candidate(20_260_815, -100_000)])
        ]
        let match = try #require(ScheduleDiscovery.match(
            occurrences: occurrences, config: monthlyConfig(20_260_615),
            accountId: "acct-1"
        ).first)
        #expect(!match.exactAmount)
        #expect(match.exactDate)
    }

    @Test func amountsOutsideTheThresholdDoNotMatch() throws {
        let occurrences = try [
            (date: #require(DayDate(yyyymmdd: 20_260_615)), transactions: [candidate(20_260_615, -100_000)]),
            (date: #require(DayDate(yyyymmdd: 20_260_715)), transactions: [candidate(20_260_715, -150_000)]),
            (date: #require(DayDate(yyyymmdd: 20_260_815)), transactions: [candidate(20_260_815, -100_000)])
        ]
        #expect(ScheduleDiscovery.match(
            occurrences: occurrences, config: monthlyConfig(20_260_615),
            accountId: "acct-1"
        ).isEmpty)
    }

    /// A gap in the middle disqualifies the pattern outright.
    @Test func aMissingOccurrenceDisqualifiesThePattern() throws {
        let occurrences = try [
            (date: #require(DayDate(yyyymmdd: 20_260_615)), transactions: [candidate(20_260_615, -100_000)]),
            (date: #require(DayDate(yyyymmdd: 20_260_715)), transactions: [ScheduleDiscovery.Candidate]()),
            (date: #require(DayDate(yyyymmdd: 20_260_815)), transactions: [candidate(20_260_815, -100_000)])
        ]
        #expect(ScheduleDiscovery.match(
            occurrences: occurrences, config: monthlyConfig(20_260_615),
            accountId: "acct-1"
        ).isEmpty)
    }

    @Test func differentPayeesDoNotMatchEachOther() throws {
        let occurrences = try [
            (date: #require(DayDate(yyyymmdd: 20_260_615)), transactions: [candidate(20_260_615, -100_000, payee: "p1")]),
            (date: #require(DayDate(yyyymmdd: 20_260_715)), transactions: [candidate(20_260_715, -100_000, payee: "p2")]),
            (date: #require(DayDate(yyyymmdd: 20_260_815)), transactions: [candidate(20_260_815, -100_000, payee: "p1")])
        ]
        #expect(ScheduleDiscovery.match(
            occurrences: occurrences, config: monthlyConfig(20_260_615),
            accountId: "acct-1"
        ).isEmpty)
    }

    @Test func datesThatDriftScoreLowerAndAreNotExact() throws {
        let occurrences = try [
            (date: #require(DayDate(yyyymmdd: 20_260_615)), transactions: [candidate(20_260_616, -100_000)]),
            (date: #require(DayDate(yyyymmdd: 20_260_715)), transactions: [candidate(20_260_715, -100_000)]),
            (date: #require(DayDate(yyyymmdd: 20_260_815)), transactions: [candidate(20_260_815, -100_000)])
        ]
        let match = try #require(ScheduleDiscovery.match(
            occurrences: occurrences, config: monthlyConfig(20_260_615),
            accountId: "acct-1"
        ).first)
        #expect(!match.exactDate)
        #expect(match.rank == 2.5)
    }

    @Test func indexWindowsTwoDaysEitherSide() throws {
        let index = ScheduleDiscovery.CandidateIndex([
            candidate(20_260_813, -1), candidate(20_260_815, -2), candidate(20_260_818, -3)
        ])
        let near = try index.near(#require(DayDate(yyyymmdd: 20_260_815)), days: 2)
        #expect(near.count == 2) // the 13th and the 15th; the 18th is outside
    }

    @Test func proposalOperatorsFollowHowExactlyItMatched() {
        let proposal = ScheduleDiscovery.Proposal(
            accountId: "acct-1", payeeId: "p1", amount: -100_000,
            config: monthlyConfig(20_260_615), exactDate: true, exactAmount: false
        )
        #expect(proposal.formFields.amountOp == .isApprox)
        #expect(proposal.formFields.postsTransaction == false)
    }
}
