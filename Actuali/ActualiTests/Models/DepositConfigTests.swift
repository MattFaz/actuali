import Foundation
import Testing
@testable import Actuali

struct DepositConfigTests {
    private let opened = DayDate(year: 2026, month: 1, day: 15)

    private func deposit(
        kind: DepositConfig.Kind = .fixed,
        amount: Int = 10_000_000,
        rate: Double = 7,
        compounding: DepositConfig.Compounding = .quarterly,
        termMonths: Int = 60
    ) -> DepositConfig {
        DepositConfig(
            kind: kind, amount: amount, annualRatePercent: rate,
            compounding: compounding, openedOn: opened, termMonths: termMonths
        )
    }

    // MARK: - Wire format

    @Test func roundTripsThroughJSON() throws {
        for kind in DepositConfig.Kind.allCases {
            for compounding in DepositConfig.Compounding.allCases {
                let config = deposit(kind: kind, compounding: compounding)
                let decoded = try JSONDecoder().decode(
                    DepositConfig.self, from: JSONEncoder().encode(config)
                )
                #expect(decoded == config)
            }
        }
    }

    /// The opening day crosses the wire as a `YYYYMMDD` integer — Actual's own
    /// date convention — rather than dragging a `Codable` conformance onto
    /// `DayDate` for this one use.
    @Test func theOpeningDayIsStoredAsAYYYYMMDDInteger() throws {
        let data = try JSONEncoder().encode(deposit())
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(json["openedOn"] as? Int == 20_260_115)
    }

    @Test func decodesAConfigWrittenBeforeCompoundingExisted() throws {
        let json = Data("""
        {"kind":"fixed","amount":10000000,"annualRatePercent":7,
         "openedOn":20260115,"termMonths":60}
        """.utf8)

        let decoded = try JSONDecoder().decode(DepositConfig.self, from: json)

        // Quarterly is what fixed and recurring deposits overwhelmingly use,
        // so it is the safest thing to assume of a config that didn't say.
        #expect(decoded.compounding == .quarterly)
        #expect(decoded.termMonths == 60)
    }

    /// Every figure is measured from the opening day, so unlike the compounding
    /// frequency there is no sane fallback — better to fail the decode.
    @Test func refusesAConfigWithAnImpossibleOpeningDay() {
        let json = Data("""
        {"kind":"fixed","amount":10000000,"annualRatePercent":7,
         "compounding":4,"openedOn":20261332,"termMonths":60}
        """.utf8)

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(DepositConfig.self, from: json)
        }
    }

    // MARK: - Dates

    @Test func maturityIsTheTermPastTheOpeningDay() {
        #expect(deposit(termMonths: 60).maturityDate == DayDate(year: 2031, month: 1, day: 15))
        #expect(deposit(termMonths: 6).maturityDate == DayDate(year: 2026, month: 7, day: 15))
    }

    /// A month only counts once the anniversary day has come round, so the
    /// deposit doesn't claim a month it hasn't finished.
    @Test func elapsedMonthsCountWholeMonthsFromTheOpeningDay() {
        let config = deposit()
        #expect(config.monthsElapsed(on: DayDate(year: 2026, month: 1, day: 15)) == 0)
        #expect(config.monthsElapsed(on: DayDate(year: 2026, month: 2, day: 14)) == 0)
        #expect(config.monthsElapsed(on: DayDate(year: 2026, month: 2, day: 15)) == 1)
        #expect(config.monthsElapsed(on: DayDate(year: 2027, month: 1, day: 15)) == 12)
    }

    @Test func aDateBeforeOpeningReadsAsMonthZero() {
        #expect(deposit().monthsElapsed(on: DayDate(year: 2025, month: 6, day: 1)) == 0)
    }

    @Test func remainingMonthsRunDownAndStopAtZero() {
        let config = deposit(termMonths: 12)
        #expect(config.monthsRemaining(on: opened) == 12)
        #expect(config.monthsRemaining(on: DayDate(year: 2026, month: 7, day: 15)) == 6)
        #expect(config.monthsRemaining(on: DayDate(year: 2030, month: 1, day: 1)) == 0)
    }

    @Test func maturityIsReachedOnTheDayNotAfterIt() {
        let config = deposit(termMonths: 12)
        #expect(!config.hasMatured(on: DayDate(year: 2027, month: 1, day: 14)))
        #expect(config.hasMatured(on: DayDate(year: 2027, month: 1, day: 15)))
    }

    @Test func progressRunsFromZeroToOneAndStopsThere() {
        let config = deposit(termMonths: 12)
        #expect(config.fractionElapsed(on: opened) == 0)
        #expect(config.fractionElapsed(on: DayDate(year: 2026, month: 7, day: 15)) == 0.5)
        #expect(config.fractionElapsed(on: DayDate(year: 2030, month: 1, day: 1)) == 1)
    }

    /// A zero-month term is already over rather than dividing by zero.
    @Test func aZeroTermIsCompleteRatherThanUndefined() {
        #expect(deposit(termMonths: 0).fractionElapsed(on: opened) == 1)
    }

    // MARK: - Value

    @Test func valueAndInterestAgreeWithTheEngine() {
        let config = deposit()
        let maturity = DayDate(year: 2031, month: 1, day: 15)

        #expect(config.value(on: maturity) == 14_147_782)
        #expect(config.maturityValue == 14_147_782)
        #expect(config.deposited(on: maturity) == 10_000_000)
        #expect(config.interestEarned(on: maturity) == 4_147_782)
        #expect(config.totalInterest == 4_147_782)
    }

    @Test func aRecurringDepositEarnsNothingOnItsFirstDay() {
        let config = deposit(kind: .recurring, amount: 500_000, termMonths: 24)

        #expect(config.value(on: opened) == 500_000)
        #expect(config.deposited(on: opened) == 500_000)
        #expect(config.interestEarned(on: opened) == 0)
    }

    @Test func totalInterestOnARecurringDepositCountsEveryInstalment() {
        let config = deposit(kind: .recurring, amount: 500_000, termMonths: 24)

        #expect(config.maturityValue == 12_835_737)
        #expect(config.totalInterest == 835_737)
    }
}
