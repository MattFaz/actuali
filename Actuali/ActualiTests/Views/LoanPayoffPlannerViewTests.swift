import Foundation
import Testing
@testable import Actuali

struct LoanPayoffPlannerViewTests {
    private let start = DayDate(year: 2022, month: 12, day: 1)

    // MARK: - Duration

    @Test func durationReadsYearsThenMonths() {
        #expect(LoanPayoffPlannerView.durationText(months: 71) == "5 yrs, 11 mos")
        #expect(LoanPayoffPlannerView.durationText(months: 24) == "2 yrs")
        #expect(LoanPayoffPlannerView.durationText(months: 7) == "7 mos")
    }

    /// YNAB writes "1 yr, 3 mos", not "1 yrs, 3 mos".
    @Test func durationUsesSingularsWhereItShould() {
        #expect(LoanPayoffPlannerView.durationText(months: 15) == "1 yr, 3 mos")
        #expect(LoanPayoffPlannerView.durationText(months: 13) == "1 yr, 1 mo")
        #expect(LoanPayoffPlannerView.durationText(months: 12) == "1 yr")
        #expect(LoanPayoffPlannerView.durationText(months: 1) == "1 mo")
    }

    /// A term that rounds to nothing still reads as a duration rather than an
    /// empty string, which is what an already-cleared loan would show.
    @Test func durationHandlesZero() {
        #expect(LoanPayoffPlannerView.durationText(months: 0) == "0 mos")
    }

    // MARK: - Payoff label

    /// A one-month term pays off in the month it starts, not the next one.
    @Test func payoffLabelCountsTheStartingMonth() {
        let en = Locale(identifier: "en_US")

        #expect(LoanPayoffPlannerView.payoffLabel(startingMonth: start, months: 1, locale: en) == "Dec 2022")
        #expect(LoanPayoffPlannerView.payoffLabel(startingMonth: start, months: 2, locale: en) == "Jan 2023")
    }

    /// The screenshot case: 72 payments from Dec 2022 lands on Nov 2028.
    @Test func payoffLabelMatchesTheSimulatorScreenshot() {
        let en = Locale(identifier: "en_US")

        #expect(LoanPayoffPlannerView.payoffLabel(startingMonth: start, months: 72, locale: en) == "Nov 2028")
    }

    @Test func extraLabelNamesTheMonthItApplies() {
        let en = Locale(identifier: "en_US")

        #expect(LoanPayoffPlannerView.extraLabel(month: start, locale: en).contains("Dec 2022"))
    }

    // MARK: - Savings sentence

    @Test func savingsTextCarriesBothFigures() {
        let text = LoanPayoffPlannerView.savingsText(interest: "$835.80", months: 15)

        #expect(text.contains("$835.80"))
        #expect(text.contains("1 yr, 3 mos"))
    }

    // MARK: - Burndown points

    /// The curve opens at what is owed today, a month before the first
    /// payment, so the first segment shows that payment's progress.
    @Test func burndownOpensAtTodaysBalance() throws {
        let schedule = try #require(LoanAmortization.schedule(
            balance: 2_200_000,
            annualRatePercent: 6,
            payment: 36500,
            startingMonth: start
        ))
        let points = schedule.balanceOverTime(openingBalance: 2_200_000)

        #expect(points.count == schedule.paymentCount + 1)
        #expect(points.first?.balance == 2_200_000)
        #expect(points.first?.month == DayDate(year: 2022, month: 11, day: 1))
        #expect(points[1].month == start)
        #expect(points.last?.balance == 0)
    }

    @Test func burndownIsEmptyForAClearedLoan() throws {
        let schedule = try #require(LoanAmortization.schedule(
            balance: 0,
            annualRatePercent: 6,
            payment: 36500,
            startingMonth: start
        ))

        #expect(schedule.balanceOverTime(openingBalance: 0).isEmpty)
    }

    @Test func burndownFallsMonotonically() throws {
        let schedule = try #require(LoanAmortization.schedule(
            balance: 2_200_000,
            annualRatePercent: 6,
            payment: 36500,
            startingMonth: start
        ))
        let balances = schedule.balanceOverTime(openingBalance: 2_200_000).map(\.balance)

        #expect(zip(balances, balances.dropFirst()).allSatisfy { $0 >= $1 })
    }
}
