import Foundation
import Testing
@testable import Actuali

struct DepositGrowthTests {
    private let opened = DayDate(year: 2026, month: 1, day: 1)

    /// A ₹100,000-shaped fixed deposit: 1,000,000 cents at 7% for five years,
    /// compounding quarterly — the default terms a bank offers.
    private func fixedDeposit(
        amount: Int = 10_000_000,
        rate: Double = 7,
        compounding: DepositConfig.Compounding = .quarterly,
        termMonths: Int = 60
    ) -> DepositConfig {
        DepositConfig(
            kind: .fixed, amount: amount, annualRatePercent: rate,
            compounding: compounding, openedOn: opened, termMonths: termMonths
        )
    }

    /// A recurring deposit: 5,000 cents a month for two years at 7%, quarterly.
    private func recurringDeposit(
        amount: Int = 500_000,
        rate: Double = 7,
        compounding: DepositConfig.Compounding = .quarterly,
        termMonths: Int = 24
    ) -> DepositConfig {
        DepositConfig(
            kind: .recurring, amount: amount, annualRatePercent: rate,
            compounding: compounding, openedOn: opened, termMonths: termMonths
        )
    }

    // MARK: - Compounding periods

    @Test func periodsCountWholeCompoundingIntervalsOnly() {
        #expect(DepositGrowth.completedPeriods(afterMonths: 0, compounding: .quarterly) == 0)
        #expect(DepositGrowth.completedPeriods(afterMonths: 2, compounding: .quarterly) == 0)
        #expect(DepositGrowth.completedPeriods(afterMonths: 3, compounding: .quarterly) == 1)
        #expect(DepositGrowth.completedPeriods(afterMonths: 11, compounding: .quarterly) == 3)
        #expect(DepositGrowth.completedPeriods(afterMonths: 12, compounding: .monthly) == 12)
        #expect(DepositGrowth.completedPeriods(afterMonths: 12, compounding: .annually) == 1)
    }

    @Test func everyCompoundingFrequencyDividesTheYearEvenly() {
        for frequency in DepositConfig.Compounding.allCases {
            #expect(frequency.periodMonths * frequency.rawValue == 12)
        }
    }

    // MARK: - Fixed deposits

    /// 1,000,000 at 7% quarterly for 5 years: 20 quarters at 1.75% each.
    @Test func fixedDepositCompoundsToItsMaturityValue() {
        #expect(DepositGrowth.value(fixedDeposit(), afterMonths: 60) == 14_147_782)
    }

    /// Interest credits on whole quarters, so the value doesn't move at all
    /// until the first one closes — it steps rather than sloping.
    @Test func fixedDepositIsWorthItsPrincipalUntilTheFirstPeriodCloses() {
        let deposit = fixedDeposit()
        #expect(DepositGrowth.value(deposit, afterMonths: 0) == 10_000_000)
        #expect(DepositGrowth.value(deposit, afterMonths: 2) == 10_000_000)
        #expect(DepositGrowth.value(deposit, afterMonths: 3) == 10_175_000)
    }

    @Test func fixedDepositGrowsPartWayThroughTheTerm() {
        #expect(DepositGrowth.value(fixedDeposit(), afterMonths: 30) == 11_894_445)
    }

    /// A matured deposit stops earning. Without the clamp the projection would
    /// keep compounding money the bank has already paid out.
    @Test func aMaturedFixedDepositStopsGrowing() {
        let deposit = fixedDeposit()
        let atMaturity = DepositGrowth.value(deposit, afterMonths: 60)
        #expect(DepositGrowth.value(deposit, afterMonths: 120) == atMaturity)
        #expect(DepositGrowth.value(deposit, afterMonths: 600) == atMaturity)
    }

    @Test func moreFrequentCompoundingEarnsMore() {
        let annual = DepositGrowth.value(fixedDeposit(compounding: .annually), afterMonths: 60)
        let quarterly = DepositGrowth.value(fixedDeposit(compounding: .quarterly), afterMonths: 60)
        let monthly = DepositGrowth.value(fixedDeposit(compounding: .monthly), afterMonths: 60)

        #expect(annual == 14_025_517)
        #expect(quarterly == 14_147_782)
        #expect(monthly == 14_176_253)
        #expect(annual < quarterly)
        #expect(quarterly < monthly)
    }

    @Test func aZeroRateFixedDepositReturnsExactlyWhatWentIn() {
        let deposit = fixedDeposit(rate: 0)
        #expect(DepositGrowth.value(deposit, afterMonths: 60) == 10_000_000)
        #expect(DepositGrowth.deposited(deposit, afterMonths: 60) == 10_000_000)
    }

    // MARK: - Recurring deposits

    /// Each instalment compounds only for the time since it was paid, so the
    /// total is worth more than the deposits but far less than the same sum
    /// left in from day one.
    @Test func recurringDepositCompoundsEachInstalmentForItsOwnTime() {
        let deposit = recurringDeposit()
        #expect(DepositGrowth.value(deposit, afterMonths: 24) == 12_835_737)
        #expect(DepositGrowth.deposited(deposit, afterMonths: 24) == 12_000_000)
    }

    @Test func theFirstInstalmentLandsOnTheOpeningDay() {
        let deposit = recurringDeposit()
        #expect(DepositGrowth.instalmentsMade(deposit, afterMonths: 0) == 1)
        #expect(DepositGrowth.value(deposit, afterMonths: 0) == 500_000)
    }

    @Test func recurringDepositGrowsPartWayThroughTheTerm() {
        #expect(DepositGrowth.value(recurringDeposit(), afterMonths: 12) == 6_695_275)
    }

    /// Instalments stop at the end of the term — a two-year RD takes 24 of
    /// them however long the account stays open afterwards.
    @Test func instalmentsStopAtTheEndOfTheTerm() {
        let deposit = recurringDeposit()
        #expect(DepositGrowth.instalmentsMade(deposit, afterMonths: 23) == 24)
        #expect(DepositGrowth.instalmentsMade(deposit, afterMonths: 100) == 24)
        #expect(DepositGrowth.deposited(deposit, afterMonths: 100) == 12_000_000)
    }

    @Test func aMaturedRecurringDepositStopsGrowing() {
        let deposit = recurringDeposit()
        let atMaturity = DepositGrowth.value(deposit, afterMonths: 24)
        #expect(DepositGrowth.value(deposit, afterMonths: 60) == atMaturity)
    }

    @Test func aZeroRateRecurringDepositIsJustTheInstalmentsAddedUp() {
        let deposit = recurringDeposit(rate: 0)
        #expect(DepositGrowth.value(deposit, afterMonths: 24) == 12_000_000)
    }

    // MARK: - Degenerate inputs

    @Test func anEmptyDepositIsWorthNothing() {
        #expect(DepositGrowth.value(fixedDeposit(amount: 0), afterMonths: 60) == 0)
        #expect(DepositGrowth.deposited(fixedDeposit(amount: 0), afterMonths: 60) == 0)
    }

    @Test func aZeroTermDepositNeverLeavesItsOpeningDay() {
        let deposit = fixedDeposit(termMonths: 0)
        #expect(DepositGrowth.value(deposit, afterMonths: 12) == 10_000_000)
        #expect(DepositGrowth.curve(deposit).isEmpty)
    }

    /// A corrupt term can't be allowed to drive the loop — the cap is the same
    /// fifty years `LoanAmortization` uses.
    @Test func anAbsurdTermIsCappedRatherThanLoopingForever() {
        let deposit = recurringDeposit(termMonths: 10000)
        #expect(DepositGrowth.instalmentsMade(deposit, afterMonths: 10000) == DepositGrowth.maxTermMonths)
    }

    @Test func negativeElapsedMonthsReadAsTheOpeningDay() {
        #expect(DepositGrowth.value(fixedDeposit(), afterMonths: -12) == 10_000_000)
    }

    // MARK: - Growth curve

    @Test func theCurveRunsFromOpeningToMaturityInclusive() throws {
        let deposit = fixedDeposit()
        let curve = DepositGrowth.curve(deposit)

        #expect(curve.count == 61)
        let first = try #require(curve.first)
        let last = try #require(curve.last)
        #expect(first.month == opened)
        #expect(first.value == 10_000_000)
        #expect(last.month == DayDate(year: 2031, month: 1, day: 1))
        #expect(last.value == deposit.maturityValue)
    }

    @Test func theCurveNeverFallsAndCarriesItsOwnDepositedBaseline() throws {
        let curve = DepositGrowth.curve(recurringDeposit())

        #expect(curve.count == 25)
        for (earlier, later) in zip(curve, curve.dropFirst()) {
            #expect(earlier.value <= later.value)
            #expect(earlier.deposited <= later.deposited)
        }
        // The gap between the two series is the interest.
        let last = try #require(curve.last)
        #expect(last.value - last.deposited == 835_737)
    }

    @Test func curvePointsAreIdentifiedByTheirMonth() throws {
        let curve = DepositGrowth.curve(fixedDeposit())
        let first = try #require(curve.first)
        #expect(first.id == opened.yyyymmdd)
        #expect(Set(curve.map(\.id)).count == curve.count)
    }
}
