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
        contributionFrequency: DepositConfig.ContributionFrequency = .monthly,
        termMonths: Int = 24
    ) -> DepositConfig {
        DepositConfig(
            kind: .recurring, amount: amount, annualRatePercent: rate,
            compounding: compounding, contributionFrequency: contributionFrequency,
            openedOn: opened, termMonths: termMonths
        )
    }

    // MARK: - Compounding periods

    @Test func periodsCountWholeCompoundingIntervalsOnly() {
        let start = DayDate(year: 2026, month: 1, day: 15)

        #expect(DepositGrowth.completedPeriods(from: start, to: start, compounding: .quarterly) == 0)
        #expect(DepositGrowth.completedPeriods(from: start, to: start.adding(months: 2), compounding: .quarterly) == 0)
        #expect(DepositGrowth.completedPeriods(from: start, to: start.adding(months: 3), compounding: .quarterly) == 1)
        #expect(DepositGrowth.completedPeriods(from: start, to: start.adding(months: 11), compounding: .quarterly) == 3)
        #expect(DepositGrowth.completedPeriods(from: start, to: start.adding(months: 12), compounding: .monthly) == 12)
        #expect(DepositGrowth.completedPeriods(from: start, to: start.adding(months: 12), compounding: .annually) == 1)
    }

    @Test func dayBasedFrequenciesCountOnlyWholePeriods() {
        let start = DayDate(year: 2026, month: 1, day: 1)

        #expect(DepositGrowth.completedPeriods(from: start, to: start, compounding: .daily) == 0)
        #expect(DepositGrowth.completedPeriods(from: start, to: start.adding(days: 1), compounding: .daily) == 1)
        #expect(DepositGrowth.completedPeriods(from: start, to: start.adding(days: 6), compounding: .weekly) == 0)
        #expect(DepositGrowth.completedPeriods(from: start, to: start.adding(days: 7), compounding: .weekly) == 1)
        #expect(DepositGrowth.completedPeriods(from: start, to: start.adding(days: 13), compounding: .biWeekly) == 0)
        #expect(DepositGrowth.completedPeriods(from: start, to: start.adding(days: 14), compounding: .biWeekly) == 1)
    }

    @Test func monthBasedFrequenciesRespectClampedCalendarAnniversaries() {
        let start = DayDate(year: 2026, month: 1, day: 31)
        let quarterEnd = start.adding(months: 3)

        #expect(quarterEnd == DayDate(year: 2026, month: 4, day: 30))
        #expect(DepositGrowth.completedPeriods(
            from: start, to: quarterEnd.adding(days: -1), compounding: .quarterly
        ) == 0)
        #expect(DepositGrowth.completedPeriods(from: start, to: quarterEnd, compounding: .quarterly) == 1)
    }

    @Test func compoundingFrequenciesDeclareTheirExplicitPeriods() {
        let expected: [(DepositConfig.Compounding, DepositConfig.Period, Int)] = [
            (.daily, .days(1), 365),
            (.weekly, .days(7), 52),
            (.biWeekly, .days(14), 26),
            (.monthly, .months(1), 12),
            (.quarterly, .months(3), 4),
            (.semiAnnually, .months(6), 2),
            (.annually, .months(12), 1),
        ]

        for (frequency, period, periodsPerYear) in expected {
            #expect(frequency.period == period)
            #expect(frequency.rawValue == periodsPerYear)
        }
    }

    @Test func contributionFrequenciesDeclareTheirExplicitPeriods() {
        let expected: [(DepositConfig.ContributionFrequency, DepositConfig.Period)] = [
            (.weekly, .days(7)),
            (.biWeekly, .days(14)),
            (.monthly, .months(1)),
            (.quarterly, .months(3)),
            (.annually, .months(12)),
        ]

        for (frequency, period) in expected {
            #expect(frequency.period == period)
        }
    }

    @Test func dayNumberDateArithmeticHandlesLeapAndCenturyBoundaries() {
        #expect(DayDate(year: 1970, month: 1, day: 1).dayNumber == 0)

        let leapDay = DayDate(year: 2024, month: 2, day: 29)
        let february = DayDate(year: 2024, month: 2, day: 28)
        let march = DayDate(year: 2024, month: 3, day: 1)
        #expect(february.days(until: march) == 2)
        #expect(february.adding(days: 1) == leapDay)
        #expect(leapDay.adding(days: 1) == march)
        #expect(march.adding(days: -1) == leapDay)

        let nonLeapCentury = DayDate(year: 1900, month: 2, day: 28)
        let leapCenturyFebruary28 = DayDate(year: 2000, month: 2, day: 28)
        let leapCenturyFebruary29 = DayDate(year: 2000, month: 2, day: 29)
        let leapCenturyMarch = DayDate(year: 2000, month: 3, day: 1)
        #expect(nonLeapCentury.days(until: DayDate(year: 1900, month: 3, day: 1)) == 1)
        #expect(leapCenturyFebruary28.days(until: leapCenturyMarch) == 2)
        #expect(nonLeapCentury.adding(days: 1) == DayDate(year: 1900, month: 3, day: 1))
        #expect(leapCenturyFebruary28.adding(days: 1) == leapCenturyFebruary29)
        #expect(leapCenturyFebruary29.adding(days: 1) == leapCenturyMarch)
        #expect(DayDate(year: 1900, month: 1, day: 31).adding(months: 1) == nonLeapCentury)
        #expect(DayDate(year: 2000, month: 1, day: 31).adding(months: 1) == leapCenturyFebruary29)
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

    @Test func fixedDepositsUseActualDaysForDailyWeeklyAndBiWeeklyCompounding() {
        #expect(DepositGrowth.value(fixedDeposit(compounding: .daily), afterMonths: 60) == 14_192_921)
        #expect(DepositGrowth.value(fixedDeposit(compounding: .weekly), afterMonths: 60) == 14_187_336)
        #expect(DepositGrowth.value(fixedDeposit(compounding: .biWeekly), afterMonths: 60) == 14_184_003)
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

    @Test func weeklyAndBiWeeklyContributionsUseSevenAndFourteenDayIntervals() {
        let weekly = recurringDeposit(contributionFrequency: .weekly)
        let biWeekly = recurringDeposit(contributionFrequency: .biWeekly)

        #expect(DepositGrowth.instalmentsMade(weekly, on: opened.adding(days: 6)) == 1)
        #expect(DepositGrowth.instalmentsMade(weekly, on: opened.adding(days: 7)) == 2)
        #expect(DepositGrowth.instalmentsMade(biWeekly, on: opened.adding(days: 13)) == 1)
        #expect(DepositGrowth.instalmentsMade(biWeekly, on: opened.adding(days: 14)) == 2)
    }

    @Test func recurringContributionFrequenciesScheduleExpectedPayments() {
        let weekly = recurringDeposit(contributionFrequency: .weekly, termMonths: 12)
        let biWeekly = recurringDeposit(contributionFrequency: .biWeekly, termMonths: 12)
        let monthly = recurringDeposit(contributionFrequency: .monthly, termMonths: 12)
        let quarterly = recurringDeposit(contributionFrequency: .quarterly, termMonths: 12)
        let annually = recurringDeposit(contributionFrequency: .annually, termMonths: 12)

        #expect(DepositGrowth.instalmentsMade(weekly, afterMonths: 12) == 53)
        #expect(DepositGrowth.instalmentsMade(biWeekly, afterMonths: 12) == 27)
        #expect(DepositGrowth.instalmentsMade(monthly, afterMonths: 12) == 12)
        #expect(DepositGrowth.instalmentsMade(quarterly, afterMonths: 12) == 4)
        #expect(DepositGrowth.instalmentsMade(annually, afterMonths: 12) == 1)
    }

    @Test func monthEndContributionsFollowTheOpeningDayAnniversary() {
        let openingDay = DayDate(year: 2026, month: 1, day: 31)
        let config = DepositConfig(
            kind: .recurring,
            amount: 500_000,
            annualRatePercent: 0,
            compounding: .quarterly,
            openedOn: openingDay,
            termMonths: 3
        )

        #expect(DepositGrowth.instalmentsMade(config, on: DayDate(year: 2026, month: 2, day: 28)) == 2)
        #expect(DepositGrowth.instalmentsMade(config, on: DayDate(year: 2026, month: 3, day: 30)) == 2)
        #expect(DepositGrowth.instalmentsMade(config, on: DayDate(year: 2026, month: 3, day: 31)) == 3)
        #expect(DepositGrowth.instalmentsMade(config, on: config.maturityDate.adding(days: -1)) == 3)
        #expect(config.maturityValue == 1_500_000)
    }

    @Test func contributionFrequencyChangesMaturityValue() {
        let expected: [(DepositConfig.ContributionFrequency, Int)] = [
            (.weekly, 26_500_000),
            (.biWeekly, 13_500_000),
            (.monthly, 6_000_000),
            (.quarterly, 2_000_000),
            (.annually, 500_000),
        ]
        for (frequency, amount) in expected {
            let config = recurringDeposit(
                amount: 500_000,
                rate: 0,
                contributionFrequency: frequency,
                termMonths: 12
            )
            #expect(config.maturityValue == amount)
            #expect(DepositGrowth.deposited(config, on: config.maturityDate) == amount)
        }
    }

    @Test func recurringContributionsStopBeforeMaturityDate() {
        let config = recurringDeposit(
            rate: 0,
            contributionFrequency: .quarterly,
            termMonths: 12
        )
        #expect(DepositGrowth.instalmentsMade(config, on: config.maturityDate.adding(days: -1)) == 4)
        #expect(DepositGrowth.instalmentsMade(config, on: config.maturityDate) == 4)
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

    @Test func recurringDepositsUseActualDaysForDailyWeeklyAndBiWeeklyCompounding() {
        #expect(DepositGrowth.value(recurringDeposit(compounding: .daily), afterMonths: 24) == 12_920_086)
        #expect(DepositGrowth.value(recurringDeposit(compounding: .weekly), afterMonths: 24) == 12_913_992)
        #expect(DepositGrowth.value(recurringDeposit(compounding: .biWeekly), afterMonths: 24) == 12_903_933)
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

    @Test func theCurveFollowsAWeeklyContributionSchedule() throws {
        let config = recurringDeposit(
            rate: 0,
            contributionFrequency: .weekly,
            termMonths: 12
        )
        let curve = DepositGrowth.curve(config)

        #expect(curve.count == 13)
        let first = try #require(curve.first)
        let last = try #require(curve.last)
        #expect(first.deposited == 500_000)
        #expect(last.deposited == 26_500_000)
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
